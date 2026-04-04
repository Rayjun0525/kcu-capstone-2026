-- E-commerce Test Database Schema
-- Used as the target DB for all experiment scenarios (S1-S5).
-- NOTE: The `points` table is intentionally absent to enable S3 hallucination tests.

CREATE SCHEMA IF NOT EXISTS ecommerce;

-- ─────────────────────────────────────────────
-- categories
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ecommerce.categories (
    id          SERIAL      PRIMARY KEY,
    name        TEXT        NOT NULL UNIQUE,
    parent_id   INT         REFERENCES ecommerce.categories(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────
-- products
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ecommerce.products (
    id           SERIAL         PRIMARY KEY,
    name         TEXT           NOT NULL,
    description  TEXT,
    price        NUMERIC(10, 2) NOT NULL CHECK (price >= 0),
    stock        INT            NOT NULL DEFAULT 0 CHECK (stock >= 0),
    category_id  INT            REFERENCES ecommerce.categories(id),
    sku          TEXT           UNIQUE,
    is_active    BOOLEAN        NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_products_category ON ecommerce.products (category_id);
CREATE INDEX IF NOT EXISTS idx_products_is_active ON ecommerce.products (is_active);

-- ─────────────────────────────────────────────
-- customers
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ecommerce.customers (
    id           SERIAL      PRIMARY KEY,
    name         TEXT        NOT NULL,
    email        TEXT        NOT NULL UNIQUE,
    phone        TEXT,
    address      TEXT,
    joined_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_active    BOOLEAN     NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_customers_email ON ecommerce.customers (email);

-- ─────────────────────────────────────────────
-- orders
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ecommerce.orders (
    id           SERIAL      PRIMARY KEY,
    customer_id  INT         NOT NULL REFERENCES ecommerce.customers(id),
    status       TEXT        NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled')),
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0,
    ordered_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_orders_customer ON ecommerce.orders (customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status   ON ecommerce.orders (status);
CREATE INDEX IF NOT EXISTS idx_orders_ordered_at ON ecommerce.orders (ordered_at DESC);

-- ─────────────────────────────────────────────
-- order_items
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ecommerce.order_items (
    id           SERIAL         PRIMARY KEY,
    order_id     INT            NOT NULL REFERENCES ecommerce.orders(id),
    product_id   INT            NOT NULL REFERENCES ecommerce.products(id),
    qty          INT            NOT NULL CHECK (qty > 0),
    unit_price   NUMERIC(10, 2) NOT NULL CHECK (unit_price >= 0),
    subtotal     NUMERIC(12, 2) GENERATED ALWAYS AS (qty * unit_price) STORED
);

CREATE INDEX IF NOT EXISTS idx_order_items_order   ON ecommerce.order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product ON ecommerce.order_items (product_id);

-- ─────────────────────────────────────────────
-- reviews
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ecommerce.reviews (
    id          SERIAL      PRIMARY KEY,
    product_id  INT         NOT NULL REFERENCES ecommerce.products(id),
    customer_id INT         NOT NULL REFERENCES ecommerce.customers(id),
    rating      SMALLINT    NOT NULL CHECK (rating BETWEEN 1 AND 5),
    body        TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────
-- Useful view: order summary
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW ecommerce.v_order_summary AS
SELECT
    o.id            AS order_id,
    c.name          AS customer_name,
    c.email         AS customer_email,
    o.status,
    o.total_amount,
    o.ordered_at,
    COUNT(oi.id)    AS item_count
FROM ecommerce.orders o
JOIN ecommerce.customers c  ON c.id = o.customer_id
JOIN ecommerce.order_items oi ON oi.order_id = o.id
GROUP BY o.id, c.name, c.email, o.status, o.total_amount, o.ordered_at;
