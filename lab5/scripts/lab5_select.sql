/*
Запрос 1. Анализ продаж по схемам исполнения
Для каждого продавца по месяцам и схемам исполнения рассчитать количество заказов, число проданных товаров, общую выручку, сумму скидок и среднюю стоимость позиции. Учитывать сохранённые при оформлении заказа цены и схемы исполнения. Определить долю каждой схемы в выручке продавца, изменение выручки относительно предыдущего месяца и накопительную выручку. Сформировать рейтинг продавцов внутри каждой схемы по общей выручке.
*/

WITH position_sales AS (
    SELECT
        so.seller_id,
        DATE_TRUNC('month', co.ordered_at)::date AS month,
        so.scheme,
        co.order_id,
        oi.quantity,
        oi.quantity * oi.actual_price * (1 - oi.discount_percent / 100.0) AS revenue,
        oi.quantity * oi.actual_price * oi.discount_percent / 100.0 AS discount_amount
    FROM order_item oi
    JOIN customer_order co ON co.order_id = oi.order_id
    JOIN seller_offer so ON so.offer_id = oi.offer_id
    WHERE oi.status IN ('Доставлена', 'Возвращена')
), monthly_sales AS (
    SELECT
        seller_id,
        month,
        scheme,
        COUNT(DISTINCT order_id) AS orders_count,
        SUM(quantity) AS units_sold,
        SUM(revenue) AS total_revenue,
        SUM(discount_amount) AS total_discount,
        AVG(revenue) AS avg_position_value
    FROM position_sales
    GROUP BY seller_id, month, scheme
), seller_scheme_ranks AS (
    SELECT
        seller_id,
        scheme,
        SUM(total_revenue) AS scheme_revenue,
        RANK() OVER (PARTITION BY scheme ORDER BY SUM(total_revenue) DESC) AS seller_rank
    FROM monthly_sales
    GROUP BY seller_id, scheme
)
SELECT
    ms.seller_id,
    s.name AS seller_name,
    ms.month,
    ms.scheme,
    ms.orders_count,
    ms.units_sold,
    ROUND(ms.total_revenue, 2) AS total_revenue,
    ROUND(ms.total_discount, 2) AS total_discount,
    ROUND(ms.avg_position_value, 2) AS avg_position_value,
    ROUND(SUM(ms.total_revenue) OVER (PARTITION BY ms.seller_id, ms.scheme) * 100.0 / 
        NULLIF(SUM(ms.total_revenue) OVER (PARTITION BY ms.seller_id), 0), 2) AS scheme_share_pct,
    ROUND(ms.total_revenue - 
        LAG(ms.total_revenue) OVER (PARTITION BY ms.seller_id, ms.scheme ORDER BY ms.month), 2) AS revenue_change,
    ROUND(SUM(ms.total_revenue) OVER (PARTITION BY ms.seller_id, ms.scheme ORDER BY ms.month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS cumulative_revenue,
    ROUND(sr.scheme_revenue, 2) AS scheme_revenue,
    sr.seller_rank
FROM monthly_sales ms
JOIN seller s ON s.seller_id = ms.seller_id
JOIN seller_scheme_ranks sr ON sr.seller_id = ms.seller_id
    AND sr.scheme = ms.scheme
ORDER BY ms.seller_id, ms.month, ms.scheme;



/*
Запрос 2. Анализ просрочек передачи товаров
Для каждого продавца определить количество поручений, число просроченных передач, среднюю и максимальную продолжительность просрочки. Для невыполненных поручений рассчитывать просрочку на дату формирования отчёта. Дополнительно рассчитать общую сумму штрафов с учётом сторнирований, количество оспариваемых начислений и процент просроченных поручений. Определить изменение процента просрочек относительно предыдущего месяца. Вывести продавцов с долей просрочек более 10%.
*/

WITH assignment_delay_rows AS (
    SELECT
        a.assignment_id,
        a.seller_id,
        DATE_TRUNC('month', a.created_at)::date AS month,
        GREATEST(EXTRACT(EPOCH FROM (COALESCE(a.transferred_at, CURRENT_TIMESTAMP) - a.deadline_at)) / 3600.0, 0) AS delay_hours
    FROM seller_assignment a
    WHERE a.status <> 'Отменено'
), assignment_stats AS (
    SELECT
        seller_id,
        month,
        COUNT(*) AS total_assignments,
        COUNT(*) FILTER (WHERE delay_hours > 0) AS overdue_count,
        AVG(delay_hours) FILTER (WHERE delay_hours > 0) AS avg_delay_hours,
        MAX(delay_hours) FILTER (WHERE delay_hours > 0) AS max_delay_hours,
        100.0 * COUNT(*) FILTER (WHERE delay_hours > 0) / COUNT(*) AS overdue_pct,
        100.0 * SUM(COUNT(*) FILTER (WHERE delay_hours > 0)) OVER (PARTITION BY seller_id)
            / SUM(COUNT(*)) OVER (PARTITION BY seller_id) AS seller_overdue_pct
    FROM assignment_delay_rows
    GROUP BY seller_id, month
), financial_stats AS (
    SELECT
        fo.seller_id,
        -SUM(fo.amount + COALESCE(rfo.amount, 0)) AS total_penalties,
        COUNT(DISTINCT fo.operation_id) FILTER (
            WHERE EXISTS (
                SELECT 1
                FROM dispute d
                WHERE d.operation_id = fo.operation_id
                    AND d.seller_id = fo.seller_id AND d.subject = 'Штраф'
            )
        ) AS disputed_charge_count
    FROM financial_operation fo
    JOIN penalty_operation po ON po.operation_id = fo.operation_id
    LEFT JOIN reversal_operation ro ON ro.origin_operation_id = fo.operation_id
    LEFT JOIN financial_operation rfo ON rfo.operation_id = ro.operation_id
        AND rfo.type = 'Сторно' AND rfo.status = 'Проведена'
    WHERE fo.type = 'Штраф'
      AND (fo.status = 'Проведена' OR (fo.status = 'Сторнирована' AND rfo.operation_id IS NOT NULL))
    GROUP BY fo.seller_id
)
SELECT
    ast.seller_id,
    s.name AS seller_name,
    ast.month,
    ast.total_assignments,
    ast.overdue_count,
    ROUND(COALESCE(ast.avg_delay_hours, 0), 2) AS avg_delay_hours,
    ROUND(COALESCE(ast.max_delay_hours, 0), 2) AS max_delay_hours,
    ROUND(COALESCE(fs.total_penalties, 0), 2) AS total_penalties,
    COALESCE(fs.disputed_charge_count, 0) AS disputed_charge_count,
    ROUND(ast.overdue_pct, 2) AS overdue_pct,
    ROUND(ast.overdue_pct - LAG(ast.overdue_pct) OVER (PARTITION BY ast.seller_id ORDER BY ast.month), 2) AS overdue_pct_change
FROM assignment_stats ast
JOIN seller s ON s.seller_id = ast.seller_id
LEFT JOIN financial_stats fs ON fs.seller_id = ast.seller_id
WHERE ast.seller_overdue_pct > 10
ORDER BY ast.seller_id, ast.month;


/*
Запрос 3. Анализ финансового баланса продавцов
Для каждого продавца по месяцам рассчитать суммы продаж, комиссий, логистических услуг, штрафов, компенсаций и выплат. Учитывать только проведённые операции, включая сторнирования. Определить чистое изменение баланса за месяц, накопительный баланс и разницу с предыдущим месяцем. Дополнительно рассчитать средний финансовый результат за текущий и два предыдущих месяца. Вывести продавцов с отрицательным балансом или снижением финансового результата более чем на 20%.
*/

WITH operation_rows AS (
    SELECT
        fo.seller_id,
        DATE_TRUNC('month', fo.performed_at)::date AS month,
        CASE WHEN fo.type = 'Сторно' THEN ofo.type ELSE fo.type END AS operation_type,
        fo.amount
    FROM financial_operation fo
    LEFT JOIN reversal_operation ro ON ro.operation_id = fo.operation_id
    LEFT JOIN financial_operation ofo ON ofo.operation_id = ro.origin_operation_id
    WHERE fo.status = 'Проведена'
), monthly_financial AS (
    SELECT
        seller_id,
        month,
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'Продажа'), 0) AS sales_amount,
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'Комиссия'), 0) AS commission_amount,
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'Логистика'), 0) AS logistics_amount,
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'Штраф'), 0) AS penalty_amount,
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'Удержание'), 0) AS withholding_amount,
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'Компенсация'), 0) AS compensation_amount,
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'Выплата'), 0) AS payout_amount,
        SUM(amount) AS monthly_balance_change
    FROM operation_rows
    GROUP BY seller_id, month
), financial_dynamics AS (
    SELECT
        seller_id,
        month,
        sales_amount,
        commission_amount,
        logistics_amount,
        penalty_amount,
        withholding_amount,
        compensation_amount,
        payout_amount,
        monthly_balance_change,
        SUM(monthly_balance_change) OVER (PARTITION BY seller_id ORDER BY month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_balance,
        monthly_balance_change - LAG(monthly_balance_change) OVER (
            PARTITION BY seller_id ORDER BY month
        ) AS result_diff,
        AVG(monthly_balance_change) OVER (PARTITION BY seller_id ORDER BY month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS avg_3_month_result
    FROM monthly_financial
)
SELECT
    fd.seller_id,
    s.name AS seller_name,
    fd.month,
    ROUND(fd.sales_amount, 2) AS sales_amount,
    ROUND(fd.commission_amount, 2) AS commission_amount,
    ROUND(fd.logistics_amount, 2) AS logistics_amount,
    ROUND(fd.penalty_amount, 2) AS penalty_amount,
    ROUND(fd.withholding_amount, 2) AS withholding_amount,
    ROUND(fd.compensation_amount, 2) AS compensation_amount,
    ROUND(fd.payout_amount, 2) AS payout_amount,
    ROUND(fd.monthly_balance_change, 2) AS monthly_balance_change,
    ROUND(fd.cumulative_balance, 2) AS cumulative_balance,
    ROUND(fd.result_diff, 2) AS result_diff,
    ROUND(fd.result_diff * 100.0 /
        NULLIF(ABS(fd.monthly_balance_change - fd.result_diff), 0), 2) AS result_change_pct,
    ROUND(fd.avg_3_month_result, 2) AS avg_3_month_result
FROM financial_dynamics fd
JOIN seller s ON s.seller_id = fd.seller_id
WHERE fd.cumulative_balance < 0
   OR fd.result_diff * 100.0 /
        NULLIF(ABS(fd.monthly_balance_change - fd.result_diff), 0) < -20
ORDER BY fd.seller_id, fd.month;

/*
Запрос 4. Анализ возвратов товаров
Для каждого продавца и категории товаров определить количество проданных и возвращённых единиц, общую стоимость возвратов, процент возвратов и среднее время между доставкой и оформлением возврата. Учитывать частичные возвраты и фактическую стоимость позиций заказа. Определить наиболее частую причину возврата и изменение процента возвратов относительно предыдущего месяца. Дополнительно рассчитать средний процент возвратов по категории среди всех продавцов. Вывести группы с процентом возвратов выше среднего по категории.
*/

WITH sales_rows AS (
    SELECT
        oi.item_id,
        so.seller_id,
        p.category,
        DATE_TRUNC('month', co.ordered_at)::date AS month,
        oi.quantity,
        oi.actual_price * (1 - oi.discount_percent / 100.0) AS unit_price,
        sh.delivered_at
    FROM order_item oi
    JOIN customer_order co ON co.order_id = oi.order_id
    JOIN seller_offer so ON so.offer_id = oi.offer_id
    JOIN product p ON p.product_id = so.product_id
    LEFT JOIN shipment sh ON sh.shipment_id = oi.shipment_id
    WHERE oi.status IN ('Доставлена', 'Возвращена')
), monthly_sales AS (
    SELECT
        seller_id,
        category,
        month,
        SUM(quantity) AS sold_quantity
    FROM sales_rows
    GROUP BY seller_id, category, month
), refund_rows AS (
    SELECT
        sr.item_id,
        sr.seller_id,
        sr.category,
        sr.month,
        r.quantity AS returned_quantity,
        r.reason,
        r.quantity * sr.unit_price AS return_amount,
        EXTRACT(EPOCH FROM (r.created_at - sr.delivered_at)) / 86400.0 AS return_days
    FROM sales_rows sr
    JOIN refund r ON r.item_id = sr.item_id
    WHERE r.status = 'Обработан'
), monthly_returns AS (
    SELECT
        seller_id,
        category,
        month,
        SUM(returned_quantity) AS returned_quantity,
        SUM(return_amount) AS return_amount,
        AVG(return_days) FILTER (WHERE return_days >= 0) AS avg_return_days,
        MODE() WITHIN GROUP (ORDER BY reason) AS most_common_reason
    FROM refund_rows
    GROUP BY seller_id, category, month
), return_rates AS (
    SELECT
        ms.seller_id,
        ms.category,
        ms.month,
        ms.sold_quantity,
        COALESCE(mr.returned_quantity, 0) AS returned_quantity,
        COALESCE(mr.return_amount, 0) AS return_amount,
        mr.avg_return_days,
        mr.most_common_reason,
        100.0 * COALESCE(mr.returned_quantity, 0) /
            NULLIF(ms.sold_quantity, 0) AS return_pct
    FROM monthly_sales ms
    LEFT JOIN monthly_returns mr ON mr.seller_id = ms.seller_id
        AND mr.category = ms.category AND mr.month = ms.month
), return_dynamics AS (
    SELECT
        rr.seller_id,
        rr.category,
        rr.month,
        rr.sold_quantity,
        rr.returned_quantity,
        rr.return_amount,
        rr.avg_return_days,
        rr.most_common_reason,
        rr.return_pct,
        rr.return_pct - LAG(rr.return_pct) OVER (
            PARTITION BY rr.seller_id, rr.category ORDER BY rr.month
        ) AS return_pct_change,
        100.0 * SUM(rr.returned_quantity) OVER (
            PARTITION BY rr.category, rr.month
        ) / NULLIF(SUM(rr.sold_quantity) OVER (
            PARTITION BY rr.category, rr.month
        ), 0) AS category_return_pct
    FROM return_rates rr
)
SELECT
    rd.seller_id,
    s.name AS seller_name,
    rd.category,
    rd.month,
    rd.sold_quantity,
    rd.returned_quantity,
    ROUND(rd.return_amount, 2) AS return_amount,
    ROUND(rd.return_pct, 2) AS return_pct,
    ROUND(rd.avg_return_days, 2) AS avg_return_days,
    rd.most_common_reason,
    ROUND(rd.return_pct_change, 2) AS return_pct_change,
    ROUND(rd.category_return_pct, 2) AS category_return_pct
FROM return_dynamics rd
JOIN seller s ON s.seller_id = rd.seller_id
WHERE rd.return_pct > rd.category_return_pct
ORDER BY rd.seller_id, rd.category, rd.month;

/*
Запрос 5. Рейтинг продавцов по спорам
Для каждого продавца определить количество открытых, завершённых и повторно рассмотренных споров, общую оспариваемую сумму и среднюю продолжительность рассмотрения. Для каждого спора сравнить первоначальное и последнее решения, определить количество изменённых решений и сумму связанных сторнирований. Рассчитать процент решений в пользу продавца и количество споров на 100 исполненных позиций. Сформировать рейтинг продавцов по частоте споров, доле повторных рассмотрений и средней продолжительности рассмотрения.
*/

WITH decision_rows AS (
    SELECT DISTINCT
        dd.dispute_id,
        COUNT(*) OVER (PARTITION BY dd.dispute_id) AS decision_count,
        FIRST_VALUE(dd.type) OVER (PARTITION BY dd.dispute_id ORDER BY dd.decided_at, dd.decision_number
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_decision,
        LAST_VALUE(dd.type) OVER (PARTITION BY dd.dispute_id ORDER BY dd.decided_at, dd.decision_number
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_decision,
        LAST_VALUE(dd.decided_at) OVER (PARTITION BY dd.dispute_id ORDER BY dd.decided_at, dd.decision_number
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_decision_at
    FROM dispute_decision dd
), dispute_rows AS (
    SELECT
        d.dispute_id,
        d.seller_id,
        d.status,
        d.opened_at,
        ABS(fo.amount) AS disputed_amount,
        COALESCE(dr.decision_count, 0) AS decision_count,
        dr.first_decision,
        dr.last_decision,
        dr.last_decision_at,
        COALESCE(ABS(rfo.amount), 0) AS reversal_amount
    FROM dispute d
    JOIN financial_operation fo ON fo.operation_id = d.operation_id
    LEFT JOIN decision_rows dr ON dr.dispute_id = d.dispute_id
    LEFT JOIN reversal_operation ro ON ro.origin_operation_id = d.operation_id
    LEFT JOIN financial_operation rfo ON rfo.operation_id = ro.operation_id
        AND rfo.type = 'Сторно' AND rfo.status = 'Проведена'
), seller_dispute_stats AS (
    SELECT
        seller_id,
        COUNT(*) AS total_disputes,
        COUNT(*) FILTER (WHERE status IN ('Открыт', 'На рассмотрении')) AS open_disputes,
        COUNT(*) FILTER (WHERE status = 'Решен') AS completed_disputes,
        COUNT(*) FILTER (WHERE decision_count > 1) AS repeated_disputes,
        SUM(disputed_amount) AS disputed_amount,
        AVG(EXTRACT(EPOCH FROM (last_decision_at - opened_at)) / 86400.0)
            FILTER (WHERE status = 'Решен' AND last_decision_at IS NOT NULL) AS avg_review_days,
        COUNT(*) FILTER (WHERE decision_count > 1 AND first_decision <> last_decision) AS changed_decisions,
        SUM(reversal_amount) AS total_reversal_amount,
        COUNT(*) FILTER (WHERE last_decision IN ('В пользу продавца', 'Частичная компенсация')) AS favorable_decisions,
        COUNT(*) FILTER (WHERE last_decision IS NOT NULL) AS decided_disputes
    FROM dispute_rows
    GROUP BY seller_id
), executed_positions AS (
    SELECT
        so.seller_id,
        COUNT(oi.item_id) AS executed_positions
    FROM order_item oi
    JOIN seller_offer so ON so.offer_id = oi.offer_id
    WHERE oi.status IN ('Доставлена', 'Возвращена')
    GROUP BY so.seller_id
), seller_metrics AS (
    SELECT
        s.seller_id,
        s.name AS seller_name,
        COALESCE(sds.open_disputes, 0) AS open_disputes,
        COALESCE(sds.completed_disputes, 0) AS completed_disputes,
        COALESCE(sds.repeated_disputes, 0) AS repeated_disputes,
        COALESCE(sds.disputed_amount, 0) AS disputed_amount,
        sds.avg_review_days,
        COALESCE(sds.changed_decisions, 0) AS changed_decisions,
        COALESCE(sds.total_reversal_amount, 0) AS total_reversal_amount,
        100.0 * sds.favorable_decisions / NULLIF(sds.decided_disputes, 0) AS seller_favorable_pct,
        100.0 * COALESCE(sds.total_disputes, 0) / NULLIF(ep.executed_positions, 0) AS disputes_per_100,
        100.0 * sds.repeated_disputes / NULLIF(sds.total_disputes, 0) AS repeated_review_pct
    FROM seller s
    LEFT JOIN seller_dispute_stats sds ON sds.seller_id = s.seller_id
    LEFT JOIN executed_positions ep ON ep.seller_id = s.seller_id
)
SELECT
    sm.seller_id,
    sm.seller_name,
    sm.open_disputes,
    sm.completed_disputes,
    sm.repeated_disputes,
    ROUND(sm.disputed_amount, 2) AS disputed_amount,
    ROUND(sm.avg_review_days, 2) AS avg_review_days,
    sm.changed_decisions,
    ROUND(sm.total_reversal_amount, 2) AS total_reversal_amount,
    ROUND(sm.seller_favorable_pct, 2) AS seller_favorable_pct,
    ROUND(sm.disputes_per_100, 2) AS disputes_per_100,
    ROUND(sm.repeated_review_pct, 2) AS repeated_review_pct,
    RANK() OVER (ORDER BY sm.disputes_per_100 DESC NULLS LAST) AS dispute_frequency_rank,
    RANK() OVER (ORDER BY sm.repeated_review_pct DESC NULLS LAST) AS repeated_review_rank,
    RANK() OVER (ORDER BY sm.avg_review_days DESC NULLS LAST) AS avg_review_duration_rank
FROM seller_metrics sm
ORDER BY dispute_frequency_rank, repeated_review_rank, avg_review_duration_rank, sm.seller_id;
