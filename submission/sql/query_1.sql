-- Query 1: Revenue trend analysis with ranking (Spark SQL)
--
-- Approach:
--   1. monthly : revenue (price + freight_value) and transaction count per category
--                per month. HAVING removes category-months with fewer than 10 transactions.
--   2. ranked  : rank every qualifying category inside its month by revenue.
--                The rank is computed over ALL categories, before narrowing to the top 5,
--                so monthly_rank means "rank among all categories that month".
--                RANK() is used, so tied revenues share the same rank.
--   3. top5    : the 5 categories with the highest overall revenue across the whole period.
--   4. trend   : keep only the top 5 and add the previous month's revenue (LAG) and a
--                3-month rolling average. month_idx = year * 12 + month is a consecutive
--                number per calendar month, so "previous month" and "last 3 months" are
--                real calendar months even when a month is missing for a category.
--   5. final   : mom_growth_pct is NULL when the immediately preceding calendar month
--                has no row for the category (first month, or a gap), because a growth
--                figure against a non-adjacent month would be misleading.

WITH monthly AS (
    SELECT
        p.product_category_name,
        YEAR(f.order_date)                                AS year,
        MONTH(f.order_date)                               AS month,
        YEAR(f.order_date) * 12 + MONTH(f.order_date)     AS month_idx,
        SUM(f.price + f.freight_value)                    AS monthly_revenue,
        COUNT(*)                                          AS transactions
    FROM fact_order_items f
    JOIN dim_products p ON f.product_key = p.product_key
    GROUP BY p.product_category_name, YEAR(f.order_date), MONTH(f.order_date)
    HAVING COUNT(*) >= 10
),

ranked AS (
    SELECT
        monthly.*,
        RANK() OVER (PARTITION BY month_idx ORDER BY monthly_revenue DESC) AS monthly_rank
    FROM monthly
),

top5 AS (
    SELECT p.product_category_name
    FROM fact_order_items f
    JOIN dim_products p ON f.product_key = p.product_key
    GROUP BY p.product_category_name
    ORDER BY SUM(f.price + f.freight_value) DESC
    LIMIT 5
),

trend AS (
    SELECT
        product_category_name,
        year,
        month,
        month_idx,
        monthly_revenue,
        monthly_rank,
        LAG(monthly_revenue) OVER (PARTITION BY product_category_name ORDER BY month_idx) AS prev_revenue,
        LAG(month_idx)       OVER (PARTITION BY product_category_name ORDER BY month_idx) AS prev_month_idx,
        AVG(monthly_revenue) OVER (PARTITION BY product_category_name
                                   ORDER BY month_idx
                                   RANGE BETWEEN 2 PRECEDING AND CURRENT ROW) AS rolling_avg
    FROM ranked
    WHERE product_category_name IN (SELECT product_category_name FROM top5)
)

SELECT
    product_category_name,
    year,
    month,
    monthly_revenue,
    monthly_rank,
    CASE WHEN prev_month_idx = month_idx - 1 AND prev_revenue > 0
         THEN ROUND((monthly_revenue - prev_revenue) * 100.0 / prev_revenue, 2)
    END                          AS mom_growth_pct,
    ROUND(rolling_avg, 2)        AS rolling_3m_avg_revenue
FROM trend
ORDER BY product_category_name, year, month
