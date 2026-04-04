-- E-commerce Seed Data
-- Deterministic data for reproducible experiments.
-- 5 categories, 200 products, 100 customers, 500 orders, ~1500 order_items.

-- ─────────────────────────────────────────────
-- categories (5 root + 10 sub)
-- ─────────────────────────────────────────────
INSERT INTO ecommerce.categories (id, name, parent_id) VALUES
    (1,  '전자제품',      NULL),
    (2,  '의류',          NULL),
    (3,  '식품',          NULL),
    (4,  '가구',          NULL),
    (5,  '스포츠',        NULL),
    (6,  '스마트폰',      1),
    (7,  '노트북',        1),
    (8,  '남성의류',      2),
    (9,  '여성의류',      2),
    (10, '신선식품',      3),
    (11, '가공식품',      3),
    (12, '소파',          4),
    (13, '침대',          4),
    (14, '운동용품',      5),
    (15, '아웃도어',      5)
ON CONFLICT (id) DO NOTHING;

SELECT setval('ecommerce.categories_id_seq', 15, true);

-- ─────────────────────────────────────────────
-- products (200 rows, deterministic via generate_series)
-- ─────────────────────────────────────────────
INSERT INTO ecommerce.products (id, name, price, stock, category_id, sku, is_active, created_at)
SELECT
    s,
    '상품_' || s,
    round((random() * 500000 + 1000)::numeric, 2),  -- 1,000 ~ 501,000원
    floor(random() * 1000)::int,
    (ARRAY[6,7,8,9,10,11,12,13,14,15])[(s % 10) + 1],
    'SKU-' || lpad(s::text, 6, '0'),
    TRUE,
    NOW() - (random() * interval '365 days')
FROM generate_series(1, 200) s
ON CONFLICT (id) DO NOTHING;

SELECT setval('ecommerce.products_id_seq', 200, true);

-- ─────────────────────────────────────────────
-- customers (100 rows)
-- ─────────────────────────────────────────────
INSERT INTO ecommerce.customers (id, name, email, phone, address, joined_at)
SELECT
    s,
    '고객_' || s,
    'customer' || s || '@example.com',
    '010-' || lpad((1000 + s)::text, 4, '0') || '-' || lpad((s * 7 % 10000)::text, 4, '0'),
    '서울시 강남구 테헤란로 ' || s || '번길',
    NOW() - (s * interval '3 days')
FROM generate_series(1, 100) s
ON CONFLICT (id) DO NOTHING;

SELECT setval('ecommerce.customers_id_seq', 100, true);

-- ─────────────────────────────────────────────
-- orders (500 rows)
-- ─────────────────────────────────────────────
INSERT INTO ecommerce.orders (id, customer_id, status, total_amount, ordered_at)
SELECT
    s,
    (s % 100) + 1,
    (ARRAY['pending','confirmed','shipped','delivered','cancelled'])[(s % 5) + 1],
    0,  -- will be updated after order_items
    NOW() - (random() * interval '365 days')
FROM generate_series(1, 500) s
ON CONFLICT (id) DO NOTHING;

SELECT setval('ecommerce.orders_id_seq', 500, true);

-- ─────────────────────────────────────────────
-- order_items (~3 items per order = 1500 rows)
-- ─────────────────────────────────────────────
INSERT INTO ecommerce.order_items (order_id, product_id, qty, unit_price)
SELECT
    o.id AS order_id,
    ((o.id * item_num * 17) % 200) + 1 AS product_id,
    (item_num % 5) + 1                  AS qty,
    p.price                             AS unit_price
FROM generate_series(1, 500) o(id)
CROSS JOIN generate_series(1, 3) item_num
JOIN ecommerce.products p
  ON p.id = ((o.id * item_num * 17) % 200) + 1
ON CONFLICT DO NOTHING;

-- Update order total_amount
UPDATE ecommerce.orders o
SET total_amount = sub.total
FROM (
    SELECT order_id, SUM(subtotal) AS total
    FROM ecommerce.order_items
    GROUP BY order_id
) sub
WHERE o.id = sub.order_id;

-- ─────────────────────────────────────────────
-- reviews (300 rows)
-- ─────────────────────────────────────────────
INSERT INTO ecommerce.reviews (product_id, customer_id, rating, body)
SELECT
    (s % 200) + 1,
    (s % 100) + 1,
    (s % 5) + 1,
    '리뷰 내용 ' || s
FROM generate_series(1, 300) s
ON CONFLICT DO NOTHING;
