-- Query 2: Seller performance scorecard (Spark SQL)
--
-- Approach:
--   1. seller_orders : collapse the item-level fact table to one row per (seller, order),
--                      so an order with several items is counted once, not once per item.
--                      Delivery fields are order-level, so MAX() just picks that single value.
--   2. seller_stats  : per seller: order count, revenue (price + freight_value), late
--                      delivery rate and average days vs estimate. Orders that are not
--                      delivered yet have NULL delivery fields, so they are left out of
--                      the late rate and the average (an undelivered order cannot be late).
--                      Only sellers with >= 20 orders are kept.
--   3. percentiles   : PERCENT_RANK() across all qualifying sellers (0 = worst, 1 = best).
--                      late_delivery_rate and avg_days_vs_estimate are ranked in DESCENDING
--                      order, so a LOWER value gives a HIGHER percentile (inverted).
--                      Revenue is ranked ascending (more revenue = higher percentile).
--   4. composite     : 40% on-time + 30% speed + 30% revenue percentile.
--                      Percentiles are shown on a 0-100 scale. overall_rank uses RANK(),
--                      so sellers with an identical score share a rank.

WITH seller_orders AS (
    SELECT
        f.seller_key,
        f.order_id,
        SUM(f.price + f.freight_value)                                      AS order_revenue,
        MAX(f.days_delivery_vs_estimate)                                    AS days_vs_estimate,
        MAX(CASE WHEN f.is_late_delivery = true THEN 1 ELSE 0 END)          AS is_late,
        MAX(CASE WHEN f.is_late_delivery IS NOT NULL THEN 1 ELSE 0 END)     AS is_delivered
    FROM fact_order_items f
    GROUP BY f.seller_key, f.order_id
),

seller_stats AS (
    SELECT
        seller_key,
        COUNT(*)                                                  AS total_orders,
        SUM(order_revenue)                                        AS total_revenue,
        100.0 * SUM(is_late) / NULLIF(SUM(is_delivered), 0)       AS late_delivery_rate,
        AVG(days_vs_estimate)                                     AS avg_days_vs_estimate
    FROM seller_orders
    GROUP BY seller_key
    HAVING COUNT(*) >= 20
       AND SUM(is_delivered) > 0
),

percentiles AS (
    SELECT
        s.*,
        PERCENT_RANK() OVER (ORDER BY late_delivery_rate   DESC) AS on_time_p,
        PERCENT_RANK() OVER (ORDER BY avg_days_vs_estimate DESC) AS speed_p,
        PERCENT_RANK() OVER (ORDER BY total_revenue        ASC)  AS revenue_p
    FROM seller_stats s
),

scored AS (
    SELECT
        p.*,
        0.4 * on_time_p + 0.3 * speed_p + 0.3 * revenue_p AS composite
    FROM percentiles p
)

SELECT
    d.seller_id,
    d.seller_state,
    sc.total_orders,
    sc.total_revenue,
    ROUND(sc.late_delivery_rate, 2)    AS late_delivery_rate,
    ROUND(sc.avg_days_vs_estimate, 2)  AS avg_days_vs_estimate,
    ROUND(100 * sc.on_time_p, 2)       AS on_time_pctl,
    ROUND(100 * sc.speed_p, 2)         AS speed_pctl,
    ROUND(100 * sc.revenue_p, 2)       AS revenue_pctl,
    ROUND(100 * sc.composite, 2)       AS composite_score,
    RANK() OVER (ORDER BY sc.composite DESC) AS overall_rank
FROM scored sc
JOIN dim_sellers d ON sc.seller_key = d.seller_key
ORDER BY overall_rank, d.seller_id
