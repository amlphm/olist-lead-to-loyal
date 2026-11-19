-- The hidden reason Olist customers leave 1-star reviews: every SQL query from the notebook, in order (DuckDB)
-- Author: Amelie Pham

-- ===== Setup: load the CSVs (run from the folder that holds them) =====
CREATE TABLE customers AS SELECT * FROM read_csv_auto('olist_customers_dataset.csv');
CREATE TABLE geolocation AS SELECT * FROM read_csv_auto('olist_geolocation_dataset.csv');
CREATE TABLE order_items AS SELECT * FROM read_csv_auto('olist_order_items_dataset.csv');
CREATE TABLE payments AS SELECT * FROM read_csv_auto('olist_order_payments_dataset.csv');
CREATE TABLE reviews AS SELECT * FROM read_csv_auto('olist_order_reviews_dataset.csv');
CREATE TABLE orders AS SELECT * FROM read_csv_auto('olist_orders_dataset.csv');
CREATE TABLE products AS SELECT * FROM read_csv_auto('olist_products_dataset.csv');
CREATE TABLE sellers AS SELECT * FROM read_csv_auto('olist_sellers_dataset.csv');
CREATE TABLE category_translation AS SELECT * FROM read_csv_auto('product_category_name_translation.csv');
CREATE TABLE leads AS SELECT * FROM read_csv_auto('olist_marketing_qualified_leads_dataset.csv');
CREATE TABLE closed_deals AS SELECT * FROM read_csv_auto('olist_closed_deals_dataset.csv');

-- ===== 3. Data model and the customer_id trap =====
SELECT count(*) AS customer_ids, count(DISTINCT customer_unique_id) AS real_people
FROM customers;

-- ===== 4. Data quality and definitions =====
SELECT order_status,
       count(*)                                          AS orders,
       100.0 * count(*) / sum(count(*)) OVER ()          AS pct      -- share of all orders
FROM orders
GROUP BY order_status
ORDER BY orders DESC;

-- ===== 4. Data quality and definitions =====
SELECT
  (SELECT count(*) FROM orders
    WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL) AS delivered_but_no_date,
  (SELECT count(*) - count(DISTINCT order_id) FROM reviews)                     AS extra_reviews_same_order,
  (SELECT round(100.0 * avg((review_comment_message IS NOT NULL)::int), 1) FROM reviews) AS pct_reviews_with_text;

-- ===== 4. Data quality and definitions =====
CREATE OR REPLACE VIEW v_orders AS
SELECT o.order_id, c.customer_unique_id, c.customer_state,
       o.order_purchase_timestamp                                                         AS ts,
       o.order_delivered_customer_date                                                    AS delivered,
       o.order_estimated_delivery_date                                                    AS promised,
       date_diff('day', o.order_purchase_timestamp, o.order_delivered_customer_date)      AS delivery_days,
       date_diff('day', o.order_estimated_delivery_date, o.order_delivered_customer_date) AS days_vs_promise,
       o.order_delivered_customer_date > o.order_estimated_delivery_date + INTERVAL 1 DAY AS is_late,
       r.review_score,
       i.n_items, i.n_sellers
FROM orders o
JOIN customers c USING (customer_id)
LEFT JOIN (SELECT order_id, avg(review_score) AS review_score            -- one row per order first
           FROM reviews GROUP BY order_id) r USING (order_id)
LEFT JOIN (SELECT order_id, count(*) AS n_items, count(DISTINCT seller_id) AS n_sellers
           FROM order_items GROUP BY order_id) i USING (order_id)
WHERE o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL;

-- ===== 4. Data quality and definitions =====
SELECT count(*) AS delivered_orders, 100 * avg(is_late::int) AS pct_late,
       avg(delivery_days) AS avg_delivery_days, avg(review_score) AS avg_review
FROM v_orders;

-- ===== 5. Engine 1: the seller funnel =====
SELECT coalesce(l.origin, 'unknown')                               AS channel,
       count(*)                                                    AS leads,
       count(d.mql_id)                                             AS deals_won,
       100.0 * count(d.mql_id) / count(*)                          AS conversion_pct,
       median(date_diff('day', l.first_contact_date, d.won_date))  AS median_days_to_close
FROM leads l
LEFT JOIN closed_deals d USING (mql_id)      -- keeps leads that never signed
GROUP BY 1
ORDER BY leads DESC;

-- ===== 5. Engine 1: the seller funnel =====
WITH sellers_who_sold AS (SELECT DISTINCT seller_id FROM order_items)
SELECT CASE WHEN GROUPING(d.business_segment) = 1 THEN 'ALL SEGMENTS' ELSE d.business_segment END AS business_segment,
       count(*)                                         AS sellers_won,
       count(s.seller_id)                               AS sellers_with_a_sale,
       100.0 * count(s.seller_id) / count(*)            AS activation_pct
FROM closed_deals d
LEFT JOIN sellers_who_sold s USING (seller_id)
WHERE d.won_date >= '2018-01-01' AND d.won_date < '2018-06-01'
GROUP BY ROLLUP (d.business_segment)          -- ROLLUP adds the total row
ORDER BY sellers_won DESC;

-- ===== 6. Engine 2: do customers come back? =====
WITH per_person AS (SELECT customer_unique_id, count(*) AS orders FROM v_orders GROUP BY 1)
SELECT CASE WHEN orders >= 3 THEN '3+' ELSE orders::varchar END AS orders_per_customer,
       count(*) AS customers,
       100.0 * count(*) / sum(count(*)) OVER () AS pct
FROM per_person GROUP BY 1 ORDER BY 1;

-- ===== 6. Engine 2: do customers come back? =====
WITH ranked AS (
  SELECT *,
         row_number() OVER (PARTITION BY customer_unique_id ORDER BY ts) AS nth_order,     -- 1 = first order
         count(*)     OVER (PARTITION BY customer_unique_id)             AS total_orders   -- did they come back?
  FROM v_orders),
firsts AS (SELECT * FROM ranked WHERE nth_order = 1 AND ts < '2018-03-01' AND review_score IS NOT NULL)
SELECT CASE WHEN review_score <= 2 AND is_late THEN 'Late + bad review'
            WHEN review_score <= 2            THEN 'On time, bad review'
            WHEN is_late                      THEN 'Late, OK review'
            ELSE                                   'On time, OK review' END AS first_experience,
       count(*) AS customers,
       100.0 * avg((total_orders > 1)::int) AS pct_came_back
FROM firsts GROUP BY 1 ORDER BY pct_came_back DESC;

-- ===== 7. Root cause: what drives bad reviews? =====
SELECT CASE WHEN days_vs_promise <= 1  THEN '1. On time (≤1 day late)'
            WHEN days_vs_promise <= 3  THEN '2. 2–3 days late'
            WHEN days_vs_promise <= 7  THEN '3. 4–7 days late'
            WHEN days_vs_promise <= 14 THEN '4. 8–14 days late'
            ELSE                            '5. 15+ days late' END AS delivery,
       count(*)                               AS orders,
       avg(review_score)                      AS avg_stars,
       100.0 * avg((review_score <= 2)::int)  AS pct_bad_review
FROM v_orders WHERE review_score IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- ===== 7. Root cause: what drives bad reviews? =====
SELECT is_late, 100.0 * avg((review_score <= 2)::int) AS pct_bad
FROM v_orders WHERE review_score IS NOT NULL GROUP BY 1;

-- ===== 7. Root cause: what drives bad reviews? =====
SELECT date_trunc('month', ts) AS month, count(*) AS orders,
       100 * avg(is_late::int) AS pct_late, avg(review_score) AS avg_stars
FROM v_orders WHERE ts >= '2017-01-01' AND ts < '2018-09-01'
GROUP BY 1 ORDER BY 1;

-- ===== 7. Root cause: what drives bad reviews? =====
SELECT customer_state AS state, count(*) AS orders, 100 * avg(is_late::int) AS pct_late,
       avg(delivery_days) AS avg_days, avg(review_score) AS avg_stars
FROM v_orders GROUP BY 1 HAVING count(*) >= 300 ORDER BY pct_late DESC;

-- ===== 7. Root cause: what drives bad reviews? =====
SELECT CASE WHEN n_sellers > 1 THEN 'Several sellers'
            WHEN n_items > 1   THEN 'Several items, 1 seller'
            ELSE                    'Single item' END AS order_type,
       count(*)                                   AS orders,
       100.0 * avg((review_score <= 2)::int)      AS pct_bad_review,
       100.0 * avg(is_late::int)                  AS pct_flagged_late
FROM v_orders WHERE review_score IS NOT NULL
GROUP BY 1 ORDER BY pct_bad_review;

-- ===== 8. What customers say: classic NLP vs an LLM =====
SELECT review_id, review_comment_message AS text
FROM reviews
WHERE review_score <= 2 AND review_comment_message IS NOT NULL
ORDER BY review_id;

-- ===== 9. Predictive model: flag likely bad reviews *before* they're written =====
WITH items AS (
  SELECT oi.order_id, count(*) AS n_items, count(DISTINCT oi.seller_id) AS n_sellers,
         sum(price) AS price, sum(freight_value) AS freight, min(oi.seller_id) AS seller_id,
         min(p.product_category_name) AS category, sum(p.product_weight_g) AS weight_g
  FROM order_items oi LEFT JOIN products p USING (product_id) GROUP BY 1),
base AS (
  SELECT v.order_id, v.ts, v.delivered, v.customer_state, s.seller_state, i.seller_id, i.category,
         i.n_items, i.n_sellers, i.price, i.freight, i.weight_g,
         date_diff('day', v.ts, v.promised)                                   AS promised_days,
         v.delivery_days, v.days_vs_promise, v.is_late::int                   AS is_late,
         date_diff('day', o.order_approved_at, o.order_delivered_carrier_date) AS days_to_ship,
         (v.review_score <= 2)::int                                           AS bad_review
  FROM v_orders v JOIN items i USING (order_id) JOIN orders o USING (order_id)
  LEFT JOIN sellers s ON s.seller_id = i.seller_id
  WHERE v.review_score IS NOT NULL),
history AS (   -- seller's late rate on orders delivered BEFORE this purchase (no peeking into the future)
  SELECT b.order_id, count(p.order_id) AS seller_prior_orders, avg(p.is_late) AS seller_prior_late_rate
  FROM base b LEFT JOIN base p ON p.seller_id = b.seller_id AND p.delivered < b.ts
  GROUP BY 1)
SELECT * FROM base JOIN history USING (order_id)
ORDER BY order_id;
