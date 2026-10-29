from collections import defaultdict
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from getpass import getpass
import logging
import random
import re
from uuid import uuid4

import psycopg2
from psycopg2.extras import RealDictCursor
from faker import Faker

MOSCOW = timezone(timedelta(hours=3))

OPERATION_INSERTS = {
    'Продажа': 'INSERT INTO sale_operation (operation_id, item_id) VALUES (%s, %s)',
    'Комиссия': 'INSERT INTO commission_operation (operation_id, item_id) VALUES (%s, %s)',
    'Логистика': 'INSERT INTO logistic_operation (operation_id, shipment_id) VALUES (%s, %s)',
    'Штраф': 'INSERT INTO penalty_operation (operation_id, assignment_id) VALUES (%s, %s)',
    'Удержание': 'INSERT INTO withholding_operation (operation_id, refund_id) VALUES (%s, %s)',
    'Компенсация': 'INSERT INTO compensation_operation (operation_id, decision_number) VALUES (%s, %s)',
    'Выплата': 'INSERT INTO payout_operation (operation_id, contract_id) VALUES (%s, %s)',
    'Сторно': 'INSERT INTO reversal_operation (operation_id, origin_operation_id) VALUES (%s, %s)',
}

def money(value):
    return value.quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)

def item_amount(quantity, price, discount):
    return money(Decimal(quantity) * price * (1 - discount / 100))

class MarketplaceDBFiller:
    def __init__(self, db_config, seed=None, as_of=None):
        self.db_config = db_config
        self.fake = Faker('ru_RU')
        self.fake.seed_instance(seed)
        self.random = random.Random(seed)
        self.as_of = as_of or datetime.now(MOSCOW)
        self.batch = uuid4().hex[:8].upper()
        self.conn = None
        self.cursor = None
        self.orders, self.items, self.shipments, self.refunds = [], [], [], []
        self.sellers, self.offers = {}, []
        self.prices, self.contracts, self.promotions = defaultdict(list), defaultdict(list), defaultdict(list)
        self.stock, self.initial_stock = {}, {}
        self.operation_count = 0

    def connect(self):
        self.conn = psycopg2.connect(**self.db_config)
        self.cursor = self.conn.cursor(cursor_factory=RealDictCursor)
        logging.info('Подключение к PostgreSQL установлено.')

    def close(self):
        if self.cursor is not None:
            self.cursor.close()
        if self.conn is not None:
            self.conn.close()

    def rows(self, query, params=()):
        self.cursor.execute(query, params)
        return self.cursor.fetchall()

    def insert(self, query, params):
        self.cursor.execute(query, params)
        return self.cursor.fetchone()['id']

    def fetch_dictionary(self):
        self.sellers = {s['seller_id']: s for s in self.rows('SELECT * FROM seller')}
        self.offers = self.rows('''SELECT so.*, s.name AS seller_name,
            p.name AS product_name, p.article_number, p.category, p.unit
            FROM seller_offer so JOIN seller s USING (seller_id)
            JOIN product p USING (product_id) ORDER BY so.created_at, so.offer_id''')
        if not self.offers:
            raise ValueError('Нет предложений. Сначала выполни create.sql, затем insert.sql.')
        for row in self.rows('SELECT * FROM offer_price ORDER BY starts_at'):
            self.prices[row['offer_id']].append(row)
        for row in self.rows('SELECT * FROM seller_contract ORDER BY starts_at'):
            rules = {}
            for key, pattern in (
                ('commission', r'Комиссия\s+(\d+(?:[.,]\d+)?)%'),
                ('logistics', r'Логистика\s+(\d+(?:[.,]\d+)?)\s+руб'),
                ('penalty', r'Штраф\s+(\d+(?:[.,]\d+)?)\s+руб'),
            ):
                match = re.search(pattern, row['terms'])
                if match is None:
                    raise ValueError(f"В договоре {row['contract_number']} не найден тариф {key}. "
                                     'Используй основной insert.sql; insert_big.sql — отдельный пример.')
                rules[key] = Decimal(match.group(1).replace(',', '.'))
            rules['commission'] /= 100
            if not (0 < rules['commission'] < 1 and rules['logistics'] > 0 and rules['penalty'] >= 0):
                raise ValueError(f"Некорректные тарифы договора {row['contract_number']}.")
            row['rules'] = rules
            self.contracts[row['seller_id']].append(row)
        for row in self.rows('''SELECT pp.offer_id, pp.starts_at AS joined_at, pp.ends_at AS left_at,
            p.* FROM promotion_participation pp JOIN promotion p USING (promotion_id)'''):
            self.promotions[row['offer_id']].append(row)
        changes = self.rows('''SELECT r.offer_id, c.changed_at, c.previous_scheme
            FROM scheme_change_record r JOIN scheme_change c USING (change_id)''')

        owners = {}
        for offer in self.offers:
            key = (offer['seller_id'], offer['product_id'])
            if offer['status'] == 'Активно':
                if key in owners:
                    raise ValueError('Для генератора нужна одна активная версия предложения продавца на товар.')
                owners[key] = offer
        self.stock = {o['offer_id']: o['available_quantity'] for o in owners.values()}
        self.initial_stock = self.stock.copy()
        currencies = defaultdict(set)
        for offer in self.offers:
            owner = owners.get((offer['seller_id'], offer['product_id']))
            offer['stock_id'] = owner['offer_id'] if owner else None
            pack = re.search(r'упаковка\s+(\d+)\s+л\b', offer['product_name'])
            offer['pack_size'] = int(pack.group(1)) if offer['unit'] == 'л' and pack else 1
            offer['family'] = ('food' if offer['category'] == 'Консервация'
                               else 'clothing' if offer['category'] in ('Одежда', 'Обувь') else 'other')
            offer['weight'] = Decimal('0.4') if offer['unit'] == 'л' else Decimal('1')
            ends = [c['changed_at'] for c in changes if c['offer_id'] == offer['offer_id']
                    and c['previous_scheme'] == offer['scheme']]
            offer['ends_at'] = min(ends) if ends else None
            for price in self.prices[offer['offer_id']]:
                currencies[offer['seller_id']].add(price['currency'])
        if any(len(values) != 1 for values in currencies.values()):
            raise ValueError('Журнал не хранит валюту: у одного продавца нужна одна валюта расчётов.')
        logging.info('Загружены %s продавцов, %s предложений, договоры, цены и акции.', len(self.sellers), len(self.offers))

    def offers_at(self, when):
        result = []
        for offer in self.offers:
            if offer['created_at'] > when or (offer['ends_at'] and when >= offer['ends_at']):
                continue
            if offer['stock_id'] is None or self.stock[offer['stock_id']] < offer['pack_size']:
                continue
            contracts = [c for c in self.contracts[offer['seller_id']]
                         if c['starts_at'] <= when and (c['ends_at'] is None or when < c['ends_at'])]
            if not contracts:
                continue
            if len(contracts) != 1:
                raise ValueError('На дату заказа найдено несколько договоров одного продавца.')
            prices = [p for p in self.prices[offer['offer_id']]
                      if p['starts_at'] <= when and (p['ends_at'] is None or when < p['ends_at'])]
            if len(prices) != 1:
                raise ValueError(f"Для предложения {offer['offer_id']} нет единственной цены на {when}.")
            promotions = [p for p in self.promotions[offer['offer_id']] if p['status'] != 'Отменена'
                          and p['starts_at'] <= when < p['ends_at'] and p['joined_at'] <= when
                          and (p['left_at'] is None or when < p['left_at'])]
            discount = max((p['discount_percent'] for p in promotions
                            if p['type'] == 'Скидка на товар'), default=Decimal('0'))
            result.append({**offer, **prices[0], 'discount': discount,
                           'rules': contracts[0]['rules'],
                           'gift': any(p['type'] == 'Подарок' for p in promotions)})
        return result

    def change_stock(self, offer, delta):
        self.cursor.execute("""UPDATE seller_offer SET available_quantity = available_quantity + %s
            WHERE offer_id = %s AND available_quantity + %s >= 0 RETURNING available_quantity""",
            (delta, offer['stock_id'], delta))
        row = self.cursor.fetchone()
        if row is None:
            raise ValueError('Не хватает остатка. Уменьши число заказов или пересоздай данные.')
        self.stock[offer['stock_id']] = row['available_quantity']

    def fill_orders_and_items(self, num_orders):
        available_dates = [o['created_at'] for o in self.offers if o['stock_id'] is not None
                           and self.stock[o['stock_id']] >= o['pack_size']]
        if not available_dates:
            raise ValueError('Доступный запас исчерпан. Пересоздай данные или пополни остатки.')
        start = max(datetime(self.as_of.year, 1, 1, tzinfo=MOSCOW), min(available_dates))
        if start >= self.as_of:
            raise ValueError('Нет доступного периода для генерации.')
        for index in range(num_orders):
            when = start + (self.as_of - start) * ((index + self.random.random()) / num_orders)
            self.create_order(index, when)
        logging.info('Созданы %s заказов, %s позиций и %s отправлений.', len(self.orders), len(self.items), len(self.shipments))

    def create_order(self, index, when):
        offers = self.offers_at(when)
        if not offers:
            raise ValueError(f'На {when} нет доступных предложений с остатком и договором.')
        currency = self.random.choice(offers)['currency']
        offers = [o for o in offers if o['currency'] == currency]
        selected = self.random.sample(offers, self.random.randint(1, min(4, len(offers))))
        cancelled = self.random.random() < 0.08
        groups, entries = {}, []
        for offer in selected:
            packs = min(2, self.stock[offer['stock_id']] // offer['pack_size'])
            quantity = self.random.randint(1, packs) * offer['pack_size']
            key = (offer['seller_id'], offer['scheme'])
            if key not in groups:
                late = (offer['scheme'] == 'Склад продавца' and offer['rules']['penalty'] > 0
                        and self.random.random() < 0.15)
                transfer = when + timedelta(days=3 if late else 1)
                groups[key] = {'offer': offer, 'transfer': transfer,
                               'accepted': transfer + timedelta(hours=1),
                               'delivered': transfer + timedelta(days=2, hours=1), 'items': [], 'id': None}
            group = groups[key]
            state = ('Отменена' if cancelled else 'Доставлена' if self.as_of >= group['delivered']
                     else 'Отправлена' if self.as_of >= group['accepted']
                     else 'Собирается' if self.as_of >= when + timedelta(days=1) else 'Резерв')
            entry = {'offer': offer, 'quantity': quantity, 'state': state, 'group': group,
                     'total': item_amount(quantity, offer['price_value'], offer['discount']),
                     'returned': 0, 'assignment_id': None}
            entries.append(entry)
            group['items'].append(entry)
        states = {i['state'] for i in entries}
        status = ('Отменен' if cancelled else 'Доставлен' if states == {'Доставлена'}
                  else 'Отправлен' if states & {'Отправлена', 'Доставлена'}
                  else 'Собирается' if 'Собирается' in states
                  else 'Оплачен' if self.as_of >= when + timedelta(minutes=5) else 'Оформлен')
        buyer = self.fake.name()
        number = f'GEN-{self.batch}-{index + 1:04}'
        order_id = self.insert('''INSERT INTO customer_order
            (order_number, ordered_at, customer, responsible, status)
            VALUES (%s, %s, %s, %s, %s) RETURNING order_id AS id''',
            (number, when, buyer, self.fake.name(), status))
        order = {'id': order_id, 'number': number, 'when': when, 'items': entries,
                 'cancelled': cancelled, 'status': status}
        self.orders.append(order)

        for position, group in enumerate(groups.values(), 1):
            if cancelled or group['accepted'] > self.as_of:
                continue
            offer = group['offer']
            packages = sum(i['quantity'] // i['offer']['pack_size'] for i in group['items'])
            weight = sum((Decimal(i['quantity'] // i['offer']['pack_size']) * i['offer']['weight']
                          for i in group['items']), Decimal('0'))
            gift = (sum(i['quantity'] for i in group['items']
                        if i['offer']['family'] == 'food') >= 3
                    and any(i['offer']['gift'] for i in group['items']))
            group['id'] = self.insert('''INSERT INTO shipment
                (shipment_number, sender, recipient, accepted_at, weight_kg,
                 length_cm, width_cm, height_cm, comment, status)
                VALUES (%s, %s, %s, %s, %s, 40, 30, 25, %s, %s) RETURNING shipment_id AS id''',
                (f'SHP-{self.batch}-{index + 1:04}-{position}',
                 offer['seller_name'] if offer['scheme'] == 'Склад продавца' else 'Склад маркетплейса «Озеро»',
                 buyer, group['accepted'], weight,
                 'Вложена открытка с рецептом.' if gift
                 else f'Количество упаковок: {packages}. Доставка в пункт выдачи.',
                 'Доставлено' if self.as_of >= group['delivered'] else 'В пути'))
            self.shipments.append(group)

        for position, entry in enumerate(entries, 1):
            offer, group = entry['offer'], entry['group']
            entry['order'] = order
            entry['id'] = self.insert('''INSERT INTO order_item
                (order_id, offer_id, shipment_id, item_number, quantity, actual_price, discount_percent, status)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s) RETURNING item_id AS id''',
                (order_id, offer['offer_id'], group['id'], position, entry['quantity'],
                 offer['price_value'], offer['discount'], entry['state']))
            if not cancelled:
                self.change_stock(offer, -entry['quantity'])
                if offer['scheme'] == 'Склад продавца' and when + timedelta(minutes=10) <= self.as_of:
                    transferred = group['transfer'] if group['transfer'] <= self.as_of else None
                    deadline = when + timedelta(days=2)
                    assignment_status = ('Выполнено' if entry['state'] == 'Доставлена'
                        else 'Передано' if transferred else 'Просрочено' if deadline < self.as_of else 'Создано')
                    entry['assignment_id'] = self.insert('''INSERT INTO seller_assignment
                        (seller_id, item_id, created_at, deadline_at, transferred_at, status)
                        VALUES (%s, %s, %s, %s, %s, %s) RETURNING assignment_id AS id''',
                        (offer['seller_id'], entry['id'], when + timedelta(minutes=10),
                         deadline, transferred, assignment_status))
            self.items.append(entry)
        if not cancelled:
            total = sum((i['total'] for i in entries), Decimal('0'))
            self.cursor.execute('''INSERT INTO payment
                (order_id, created_at, payer, recipient, amount, currency, purpose, status)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)''',
                (order_id, min(when + timedelta(minutes=1), self.as_of), buyer, 'ООО «Озеро»',
                 total, currency, 'Оплата ' + number,
                 'Проведен' if self.as_of >= when + timedelta(minutes=5) else 'Ожидается'))

    def fill_refunds_and_disputes(self):
        for entry in self.items:
            offer, group = entry['offer'], entry['group']
            if (entry['state'] != 'Доставлена' or group['delivered'] > self.as_of - timedelta(days=7)
                    or offer['family'] not in ('clothing', 'food') or self.random.random() >= 0.25):
                continue
            packages = entry['quantity'] // offer['pack_size']
            quantity = self.random.randint(1, packages) * offer['pack_size']
            food = offer['family'] == 'food'
            condition = 'Поврежден' if food else self.random.choice(['Новый', 'Б/У'])
            returned_at = group['delivered'] + timedelta(days=2)
            refund_id = self.insert('''INSERT INTO refund
                (item_id, refund_number, created_at, quantity, reason, condition,
                 return_route, responsible, status)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'Обработан') RETURNING refund_id AS id''',
                (entry['id'], f'RET-{self.batch}-{len(self.refunds) + 1:04}', returned_at, quantity,
                 'Брак' if food else 'Не подошло', condition, 'Покупатель → пункт приёма → продавец', self.fake.name()))
            refund = {'id': refund_id, 'item': entry, 'when': returned_at,
                      'amount': item_amount(quantity, offer['price_value'], offer['discount']),
                      'restocked': condition == 'Новый', 'decision': None}
            self.refunds.append(refund)
            entry['returned'] = quantity
            if condition == 'Новый':
                self.change_stock(offer, quantity)
            if quantity == entry['quantity']:
                self.cursor.execute("UPDATE order_item SET status='Возвращена' WHERE item_id=%s", (entry['id'],))
            if not food and condition == 'Б/У':
                dispute_id = self.insert('''INSERT INTO dispute
                    (seller_id, item_id, dispute_number, opened_at, subject, description, materials, responsible, status)
                    VALUES (%s, %s, %s, %s, 'Возврат', %s, %s, %s, 'Решен') RETURNING dispute_id AS id''',
                    (offer['seller_id'], entry['id'], f'DSP-{self.batch}-{len(self.refunds):04}',
                     returned_at + timedelta(days=1), 'Продавец оспаривает возврат товара со следами использования.',
                     'Учебные фотографии товара и акт приёмки.', self.fake.name()))
                refund['decision_at'] = returned_at + timedelta(days=3)
                refund['decision'] = self.insert('''INSERT INTO dispute_decision
                    (dispute_id, decided_at, type, basis, author, responsible, status)
                    VALUES (%s, %s, 'Частичная компенсация', %s, %s, %s, 'Вступило в силу')
                    RETURNING decision_number AS id''',
                    (dispute_id, refund['decision_at'], 'По акту и фотографиям компенсировать продавцу 50% удержания.',
                     self.fake.name(), self.fake.name()))
        for order in self.orders:
            if all(i['returned'] == i['quantity'] for i in order['items']):
                self.cursor.execute("UPDATE customer_order SET status='Возвращен' WHERE order_id=%s", (order['id'],))
                self.cursor.execute("UPDATE payment SET status='Возвращен' WHERE order_id=%s", (order['id'],))
        logging.info('Созданы %s возвратов и связанные с ними споры/решения.', len(self.refunds))

    def create_operation(self, seller_id, kind, amount, when, basis_id, note, status='Проведена'):
        operation_id = self.insert('''INSERT INTO financial_operation
            (seller_id, performed_at, amount, note, type, responsible, status)
            VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING operation_id AS id''',
            (seller_id, when, money(amount), note, kind, self.fake.name(), status))
        self.cursor.execute(OPERATION_INSERTS[kind], (operation_id, basis_id))
        self.operation_count += 1
        return operation_id

    def fill_financial_operations(self):
        for entry in self.items:
            offer, group = entry['offer'], entry['group']
            if entry['state'] == 'Отменена':
                continue
            seller = offer['seller_id']
            rules = offer['rules']
            deadline = entry['order']['when'] + timedelta(days=2)
            if (entry['assignment_id'] and group['transfer'] <= self.as_of
                    and group['transfer'] > deadline and rules['penalty'] > 0):
                self.create_operation(seller, 'Штраф', -rules['penalty'], group['transfer'],
                                      entry['assignment_id'], 'Просрочка фактической передачи по поручению.')
            if entry['state'] != 'Доставлена':
                continue
            delivered = group['delivered']
            self.create_operation(seller, 'Продажа', entry['total'], delivered, entry['id'], 'Продажа после доставки.')
            fee = money(entry['total'] * rules['commission'])
            self.create_operation(seller, 'Комиссия', -fee, delivered, entry['id'], 'Комиссия по тарифу договора.')
            if delivered + timedelta(days=1) <= self.as_of and self.random.random() < 0.04:
                duplicate = self.create_operation(seller, 'Комиссия', -fee, delivered, entry['id'],
                                                  'Ошибочное повторное начисление.', 'Сторнирована')
                self.create_operation(seller, 'Сторно', fee, delivered + timedelta(days=1), duplicate,
                                      'Полная отмена только ошибочной повторной комиссии.')
        for group in self.shipments:
            if group['delivered'] > self.as_of:
                continue
            offer = group['offer']
            fee = offer['rules']['logistics']
            self.create_operation(offer['seller_id'], 'Логистика', -fee, group['delivered'],
                                  group['id'], 'Плата за доставленное отправление.')
        for refund in self.refunds:
            seller = refund['item']['offer']['seller_id']
            self.create_operation(seller, 'Удержание', -refund['amount'], refund['when'], refund['id'],
                                  'Стоимость обработанного возврата; комиссия и логистика сохраняются.')
            if refund['decision']:
                self.create_operation(seller, 'Компенсация', refund['amount'] / 2,
                                      refund['decision_at'], refund['decision'], 'Компенсация 50% по решению спора.')

    def fill_payouts(self):
        balances = self.rows('''SELECT seller_id, SUM(amount) AS balance FROM financial_operation
            WHERE seller_id = ANY(%s) GROUP BY seller_id HAVING SUM(amount) > 0''', (list(self.sellers),))
        for row in balances:
            contracts = [c for c in self.contracts[row['seller_id']] if c['starts_at'] <= self.as_of
                         and (c['ends_at'] is None or self.as_of < c['ends_at']) and c['status'] == 'Действует']
            if not contracts:
                raise ValueError(f"Нет действующего договора для выплаты продавцу {row['seller_id']}.")
            self.create_operation(row['seller_id'], 'Выплата', -money(row['balance'] / 2), self.as_of,
                                  contracts[-1]['contract_id'], 'Частичная выплата 50% положительного остатка.')

    def check_totals(self):
        errors = self.rows('''SELECT o.order_number FROM customer_order o JOIN payment p USING(order_id)
            JOIN order_item i USING(order_id) WHERE o.order_number LIKE %s
            GROUP BY o.order_number,p.amount HAVING p.amount<>
            SUM(ROUND(i.quantity*i.actual_price*(1-i.discount_percent/100),2))''', (f'GEN-{self.batch}-%',))
        if errors:
            raise ValueError('Сумма платежа отличается от суммы позиций.')
        errors = self.rows('''SELECT r.item_id FROM refund r JOIN order_item i USING(item_id)
            GROUP BY r.item_id,i.quantity HAVING SUM(r.quantity)>i.quantity''')
        if errors:
            raise ValueError('Возвращено больше товара, чем было куплено.')

        for stock_id, initial in self.initial_stock.items():
            sold = sum(i['quantity'] for i in self.items
                       if i['offer']['stock_id'] == stock_id and i['state'] != 'Отменена')
            restored = sum(r['item']['returned'] for r in self.refunds
                           if r['item']['offer']['stock_id'] == stock_id and r['restocked'])
            if self.stock[stock_id] != initial - sold + restored:
                raise ValueError('Нарушен баланс складского остатка.')
        logging.info('Проверки сумм платежей, количества возвратов и остатков пройдены.')

    def generate_all(self, num_orders=200):
        if num_orders < 1:
            raise ValueError('Количество заказов должно быть положительным.')
        if self.as_of.tzinfo is None:
            raise ValueError('Для as_of нужен часовой пояс.')
        try:
            self.connect()
            self.fetch_dictionary()
            self.fill_orders_and_items(num_orders)
            self.fill_refunds_and_disputes()
            self.fill_financial_operations()
            self.fill_payouts()
            self.check_totals()
            self.conn.commit()
            logging.info('Добавлено %s финансовых операций. Все данные сохранены. Пакет %s.', self.operation_count, self.batch)
        except Exception:
            if self.conn is not None:
                self.conn.rollback()
            raise
        finally:
            self.close()


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
    db_config = {
        'dbname': 'marketplace_ozero',
        'user': 'postgres',
        'password': getpass('Пароль PostgreSQL: '),
        'host': 'localhost',
        'port': 5432,
    }
    filler = MarketplaceDBFiller(db_config)
    try:
        filler.generate_all(num_orders=200) 
    except (psycopg2.Error, ValueError) as error:
        logging.error('Текущий запуск не сохранён: %s', error)
        raise SystemExit(1)
