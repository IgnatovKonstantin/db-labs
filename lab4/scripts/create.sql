DROP TABLE IF EXISTS reversal_operation CASCADE;
DROP TABLE IF EXISTS payout_operation CASCADE;
DROP TABLE IF EXISTS compensation_operation CASCADE;
DROP TABLE IF EXISTS withholding_operation CASCADE;
DROP TABLE IF EXISTS penalty_operation CASCADE;
DROP TABLE IF EXISTS logistic_operation CASCADE;
DROP TABLE IF EXISTS commission_operation CASCADE;
DROP TABLE IF EXISTS sale_operation CASCADE;
DROP TABLE IF EXISTS scheme_change_record CASCADE;
DROP TABLE IF EXISTS promotion_participation CASCADE;
DROP TABLE IF EXISTS dispute_decision CASCADE;
DROP TABLE IF EXISTS dispute CASCADE;
DROP TABLE IF EXISTS refund CASCADE;
DROP TABLE IF EXISTS financial_operation CASCADE;
DROP TABLE IF EXISTS payment CASCADE;
DROP TABLE IF EXISTS seller_assignment CASCADE;
DROP TABLE IF EXISTS order_item CASCADE;
DROP TABLE IF EXISTS shipment CASCADE;
DROP TABLE IF EXISTS customer_order CASCADE;
DROP TABLE IF EXISTS promotion CASCADE;
DROP TABLE IF EXISTS offer_price CASCADE;
DROP TABLE IF EXISTS scheme_change CASCADE;
DROP TABLE IF EXISTS seller_offer CASCADE;
DROP TABLE IF EXISTS product CASCADE;
DROP TABLE IF EXISTS seller_contract CASCADE;
DROP TABLE IF EXISTS seller CASCADE;


DROP TYPE IF EXISTS decision_status_enum CASCADE;
DROP TYPE IF EXISTS decision_type_enum CASCADE;
DROP TYPE IF EXISTS dispute_status_enum CASCADE;
DROP TYPE IF EXISTS dispute_subject_enum CASCADE;
DROP TYPE IF EXISTS refund_status_enum CASCADE;
DROP TYPE IF EXISTS product_condition_enum CASCADE;
DROP TYPE IF EXISTS refund_reason_enum CASCADE;
DROP TYPE IF EXISTS financial_operation_status_enum CASCADE;
DROP TYPE IF EXISTS financial_operation_type_enum CASCADE;
DROP TYPE IF EXISTS payment_status_enum CASCADE;
DROP TYPE IF EXISTS shipment_status_enum CASCADE;
DROP TYPE IF EXISTS assignment_status_enum CASCADE;
DROP TYPE IF EXISTS order_item_status_enum CASCADE;
DROP TYPE IF EXISTS order_status_enum CASCADE;
DROP TYPE IF EXISTS promotion_status_enum CASCADE;
DROP TYPE IF EXISTS promotion_type_enum CASCADE;
DROP TYPE IF EXISTS offer_status_enum CASCADE;
DROP TYPE IF EXISTS scheme_type_enum CASCADE;
DROP TYPE IF EXISTS product_status_enum CASCADE;
DROP TYPE IF EXISTS unit_of_measure_enum CASCADE;
DROP TYPE IF EXISTS contract_status_enum CASCADE;
DROP TYPE IF EXISTS seller_status_enum CASCADE;
DROP TYPE IF EXISTS seller_type_enum CASCADE;


CREATE TYPE seller_type_enum AS ENUM ('ИП', 'ООО', 'Самозанятый');
CREATE TYPE seller_status_enum AS ENUM ('Активен', 'Не активен', 'Заблокирован', 'На проверке');
CREATE TYPE contract_status_enum AS ENUM ('Действует', 'Приостановлен', 'Расторгнут', 'Истек');
CREATE TYPE unit_of_measure_enum AS ENUM ('шт', 'кг', 'уп', 'л', 'м');
CREATE TYPE product_status_enum AS ENUM ('Активен', 'Нет в наличии', 'Архив');
CREATE TYPE scheme_type_enum AS ENUM ('Склад продавца', 'Склад маркетплейса');
CREATE TYPE offer_status_enum AS ENUM ('Активно', 'Неактивно', 'Приостановлено');
CREATE TYPE promotion_type_enum AS ENUM ('Скидка на товар', 'Скидка на заказ', 'Подарок', 'Бонус');
CREATE TYPE promotion_status_enum AS ENUM ('Запланирована', 'Активна', 'Завершена', 'Отменена');
CREATE TYPE order_status_enum AS ENUM ('Оформлен', 'Оплачен', 'Собирается', 'Отправлен', 'Доставлен', 'Отменен', 'Возвращен');
CREATE TYPE order_item_status_enum AS ENUM ('Резерв', 'Собирается', 'Готова к отправке', 'Отправлена', 'Доставлена', 'Возвращена', 'Отменена');
CREATE TYPE assignment_status_enum AS ENUM ('Создано', 'Передано', 'Просрочено', 'Выполнено', 'Отменено');
CREATE TYPE shipment_status_enum AS ENUM ('Принято', 'В пути', 'В сортировке', 'Доставлено', 'Возвращается');
CREATE TYPE payment_status_enum AS ENUM ('Ожидается', 'Проведен', 'Отклонен', 'Возвращен');
CREATE TYPE financial_operation_type_enum AS ENUM ('Продажа', 'Комиссия', 'Логистика', 'Штраф', 'Удержание', 'Компенсация', 'Выплата', 'Сторно');
CREATE TYPE financial_operation_status_enum AS ENUM ('Проведена', 'Сторнирована');
CREATE TYPE refund_reason_enum AS ENUM ('Брак', 'Не подошло', 'Не доставлено', 'Иное');
CREATE TYPE product_condition_enum AS ENUM ('Новый', 'Б/У', 'Поврежден', 'Отсутствует');
CREATE TYPE refund_status_enum AS ENUM ('Оформлен', 'В пути', 'Принят на складе', 'Обработан', 'Отклонен');
CREATE TYPE dispute_subject_enum AS ENUM ('Удержание', 'Возврат', 'Штраф', 'Логистика', 'Иное');
CREATE TYPE dispute_status_enum AS ENUM ('Открыт', 'На рассмотрении', 'Решен', 'Отклонен', 'Закрыт');
CREATE TYPE decision_type_enum AS ENUM ('В пользу продавца', 'В пользу площадки', 'Частичная компенсация', 'Повторное рассмотрение', 'Отказ');
CREATE TYPE decision_status_enum AS ENUM ('Вынесено', 'Вступило в силу', 'Обжаловано', 'Отменено');


-- Продавец / E1
CREATE TABLE seller (
    seller_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(200) NOT NULL,
    type seller_type_enum NOT NULL,
    inn varchar(12) NOT NULL UNIQUE,
    kpp varchar(9) CHECK (kpp ~ '^[0-9]{9}$'),
    bank_account varchar(20) NOT NULL UNIQUE CHECK (bank_account ~ '^[0-9]{20}$'),
    legal_address text,
    phone varchar(16) CHECK(phone IS NULL OR phone ~ '^\+?[0-9]{10,15}$'),
    email varchar(100) NOT NULL CHECK (email ~ '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'),
    registered_at timestamptz NOT NULL,
    status seller_status_enum NOT NULL,

    CONSTRAINT seller_inn_check 
        CHECK ((type = 'ООО' AND inn ~ '^[0-9]{10}$') 
        OR (type IN ('ИП', 'Самозанятый') AND inn ~ '^[0-9]{12}$'))
);

-- Договор продавца / E2
CREATE TABLE seller_contract (
    contract_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id bigint NOT NULL REFERENCES seller(seller_id) 
        ON DELETE RESTRICT ON UPDATE CASCADE,
    contract_number varchar(50) NOT NULL UNIQUE,
    concluded_at timestamptz NOT NULL, 
    starts_at timestamptz NOT NULL CHECK (starts_at >= concluded_at),
    ends_at timestamptz CHECK (ends_at IS NULL OR ends_at >= starts_at),
    terms text NOT NULL,
    status contract_status_enum NOT NULL
);

-- Товар / E3
CREATE TABLE product (
    product_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    article_number varchar(50) NOT NULL UNIQUE,
    name varchar(200) NOT NULL,
    category varchar(100) NOT NULL,
    unit unit_of_measure_enum NOT NULL,
    status product_status_enum NOT NULL
);

-- Предложение продавца / E4
CREATE TABLE seller_offer (
    offer_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id bigint NOT NULL REFERENCES seller(seller_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    product_id bigint NOT NULL REFERENCES product(product_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    seller_article_number varchar(50) NOT NULL,
    scheme scheme_type_enum NOT NULL,
    available_quantity int NOT NULL CHECK (available_quantity >= 0),
    created_at timestamptz NOT NULL,
    status offer_status_enum NOT NULL
);

-- Изменение схемы исполнения / E5
CREATE TABLE scheme_change (
    change_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    changed_at timestamptz NOT NULL,
    previous_scheme scheme_type_enum NOT NULL,
    new_scheme scheme_type_enum NOT NULL CHECK (new_scheme <> previous_scheme),
    responsible varchar(100) NOT NULL
);

-- Цена предложения / E6
CREATE TABLE offer_price (
    price_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    offer_id bigint NOT NULL REFERENCES seller_offer(offer_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    price_value numeric(10, 2) NOT NULL CHECK (price_value > 0),
    currency char(3) NOT NULL,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz CHECK (ends_at IS NULL OR ends_at >= starts_at),
    terms text
);

-- Акция / E7
CREATE TABLE promotion (
    promotion_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(200) NOT NULL,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL CHECK (ends_at >= starts_at),
    discount_percent numeric(5, 2) CHECK (discount_percent IS NULL OR discount_percent BETWEEN 0 AND 100),
    type promotion_type_enum NOT NULL,
    terms text,
    status promotion_status_enum NOT NULL,

    CONSTRAINT promotion_discount_required_check 
        CHECK (type NOT IN ('Скидка на товар', 'Скидка на заказ')
        OR discount_percent IS NOT NULL)
);

-- Заказ / E8
CREATE TABLE customer_order (
    order_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_number varchar(30) NOT NULL UNIQUE,
    ordered_at timestamptz NOT NULL,
    customer varchar(200) NOT NULL,
    responsible varchar(100),
    status order_status_enum NOT NULL
);

-- Отправление / E11
CREATE TABLE shipment (
    shipment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_number varchar(30) NOT NULL UNIQUE,
    sender varchar(200) NOT NULL,
    recipient varchar(200) NOT NULL,
    accepted_at timestamptz NOT NULL,
    weight_kg numeric(10, 3) CHECK (weight_kg IS NULL OR weight_kg > 0), 
    length_cm int CHECK (length_cm IS NULL OR length_cm > 0),
    width_cm int CHECK (width_cm IS NULL OR width_cm > 0),
    height_cm int CHECK (height_cm IS NULL OR height_cm > 0),
    comment text,
    status shipment_status_enum NOT NULL
);

-- Позиция заказа / E9
CREATE TABLE order_item (
    item_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id bigint NOT NULL REFERENCES customer_order(order_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    offer_id bigint NOT NULL REFERENCES seller_offer(offer_id)
        ON DELETE RESTRICT ON UPDATE CASCADE, 
    shipment_id bigint REFERENCES shipment(shipment_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    item_number int NOT NULL CHECK (item_number > 0),
    quantity int NOT NULL CHECK (quantity > 0),
    actual_price numeric(10, 2) NOT NULL CHECK (actual_price >= 0),
    discount_percent numeric(5, 2) NOT NULL CHECK (discount_percent BETWEEN 0 AND 100),
    status order_item_status_enum NOT NULL,

    CONSTRAINT order_id_number_unique UNIQUE (order_id, item_number),
    CONSTRAINT shipment_required_check
        CHECK (status NOT IN ('Отправлена', 'Доставлена')
        OR shipment_id IS NOT NULL)
);

-- Поручение продавцу / E10
CREATE TABLE seller_assignment (
    assignment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id bigint NOT NULL REFERENCES seller(seller_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    item_id bigint NOT NULL UNIQUE REFERENCES order_item(item_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    created_at timestamptz NOT NULL,
    deadline_at timestamptz NOT NULL CHECK (deadline_at >= created_at),
    transferred_at timestamptz CHECK (transferred_at >= created_at),
    status assignment_status_enum NOT NULL,

    CONSTRAINT transferred_required_check
        CHECK (status NOT IN ('Передано', 'Выполнено')
        OR transferred_at IS NOT NULL)
);

-- Платеж / E12
CREATE TABLE payment (
    payment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id bigint NOT NULL UNIQUE REFERENCES customer_order(order_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    created_at timestamptz NOT NULL,
    payer varchar(200) NOT NULL,
    recipient varchar(200) NOT NULL,
    amount numeric(10, 2) NOT NULL CHECK (amount > 0),
    currency varchar(3) NOT NULL,
    purpose text,
    status payment_status_enum NOT NULL
);

-- Финансовая операция / E13
CREATE TABLE financial_operation (
    operation_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id bigint NOT NULL REFERENCES seller(seller_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    performed_at timestamptz NOT NULL,
    amount numeric(10, 2) NOT NULL,
    note text,
    type financial_operation_type_enum NOT NULL,
    responsible varchar(100),
    status financial_operation_status_enum NOT NULL
);

-- Возврат / E14
CREATE TABLE refund (
    refund_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id bigint NOT NULL REFERENCES order_item(item_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    refund_number varchar(30) NOT NULL UNIQUE,
    created_at timestamptz NOT NULL,
    quantity int NOT NULL CHECK (quantity > 0),
    reason refund_reason_enum NOT NULL,
    condition product_condition_enum,
    return_route text NOT NULL,
    responsible varchar(100),
    status refund_status_enum NOT NULL
);

-- Спор / E15
CREATE TABLE dispute (
    dispute_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id bigint NOT NULL REFERENCES seller(seller_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    item_id bigint NOT NULL REFERENCES order_item(item_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    dispute_number varchar(30) NOT NULL UNIQUE,
    opened_at timestamptz NOT NULL,
    subject dispute_subject_enum NOT NULL,
    description text NOT NULL,
    materials text,
    responsible varchar(100),
    status dispute_status_enum NOT NULL
);

-- Решение по спору / E16
CREATE TABLE dispute_decision (
    decision_number bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dispute_id bigint NOT NULL REFERENCES dispute(dispute_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    decided_at timestamptz NOT NULL,
    type decision_type_enum NOT NULL,
    basis text NOT NULL,
    author varchar(100) NOT NULL,
    responsible varchar(100),
    status decision_status_enum NOT NULL
);

-- Участие в акции / E17
CREATE TABLE promotion_participation (
    promotion_id bigint NOT NULL REFERENCES promotion(promotion_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    offer_id bigint NOT NULL REFERENCES seller_offer(offer_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz CHECK (ends_at IS NULL OR ends_at >= starts_at),
    PRIMARY KEY (promotion_id, offer_id)
);

-- Запись об изменении / E18
CREATE TABLE scheme_change_record (
    offer_id bigint NOT NULL REFERENCES seller_offer(offer_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    change_id bigint NOT NULL REFERENCES scheme_change(change_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    PRIMARY KEY (offer_id, change_id)
);

-- Продажа / E19
CREATE TABLE sale_operation (
    operation_id bigint PRIMARY KEY REFERENCES financial_operation(operation_id) 
        ON DELETE CASCADE ON UPDATE CASCADE,
    item_id bigint NOT NULL REFERENCES order_item(item_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- Комиссия / E20
CREATE TABLE commission_operation (
    operation_id bigint PRIMARY KEY REFERENCES financial_operation(operation_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    item_id bigint NOT NULL REFERENCES order_item(item_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- Логистика / E21
CREATE TABLE logistic_operation (
    operation_id bigint PRIMARY KEY REFERENCES financial_operation(operation_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    shipment_id bigint NOT NULL REFERENCES shipment(shipment_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- Штраф / E22
CREATE TABLE penalty_operation (
    operation_id bigint PRIMARY KEY REFERENCES financial_operation(operation_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    assignment_id bigint NOT NULL REFERENCES seller_assignment(assignment_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- Удержание / E23
CREATE TABLE withholding_operation (
    operation_id bigint PRIMARY KEY REFERENCES financial_operation(operation_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    refund_id bigint NOT NULL REFERENCES refund(refund_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- Компенсация / E24
CREATE TABLE compensation_operation (
    operation_id bigint PRIMARY KEY REFERENCES financial_operation(operation_id) 
        ON DELETE CASCADE ON UPDATE CASCADE,
    decision_number bigint NOT NULL REFERENCES dispute_decision(decision_number)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- Выплата / E25
CREATE TABLE payout_operation (
    operation_id bigint PRIMARY KEY REFERENCES financial_operation(operation_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    contract_id bigint NOT NULL REFERENCES seller_contract(contract_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
);

-- Сторно / E26
CREATE TABLE reversal_operation (
    operation_id bigint PRIMARY KEY REFERENCES financial_operation(operation_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    origin_operation_id bigint NOT NULL REFERENCES financial_operation(operation_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,

    CONSTRAINT not_self_operation 
        CHECK (origin_operation_id <> operation_id)
);
