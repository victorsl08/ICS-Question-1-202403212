-- =====================================================================
-- ICT371 Advanced Database | Question 1: Pharmacy Stock and Daily Sales
-- Target DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Run the whole file with:  psql -d your_database -f Q1_Pharmacy_Stock_and_Daily_Sales.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Database and seed data (tables first; sales are loaded at the end
--     through pr_record_sale once the function/procedure/trigger exist)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

CREATE TABLE medicines (
    medicine_id    SERIAL        PRIMARY KEY,
    medicine_name  VARCHAR(100)  NOT NULL UNIQUE,
    unit_price     NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty      INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id      SERIAL        PRIMARY KEY,
    medicine_id  INTEGER       NOT NULL REFERENCES medicines (medicine_id),
    quantity     INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price   NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on      DATE          NOT NULL
);

CREATE TABLE stock_audit (
    audit_id     SERIAL      PRIMARY KEY,
    medicine_id  INTEGER     NOT NULL REFERENCES medicines (medicine_id),
    old_qty      INTEGER     NOT NULL,
    new_qty      INTEGER     NOT NULL,
    changed_at   TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date    DATE          PRIMARY KEY,
    total_qty     INTEGER       NOT NULL DEFAULT 0,
    total_amount  NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Three medicines (sales are NOT inserted directly)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 50),
    ('Amoxicillin 250mg', 8.00, 20),
    ('Ibuprofen 200mg',   4.00, 12);

-- ---------------------------------------------------------------------
-- (b) Function fn_sale_value
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure pr_record_sale
--     Any RAISE EXCEPTION aborts the CALL, so neither table changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock INTEGER;
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    -- Lock the medicine row so two simultaneous sales cannot oversell
    SELECT stock_qty, unit_price INTO v_stock, v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;

    -- Store the CURRENT price in the sale
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- Deduct stock exactly once
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: audit stock changes (AFTER UPDATE, row level)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_stock_audit ON medicines;
CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)   -- only when stock really changes
EXECUTE FUNCTION trg_fn_stock_audit();

-- ---------------------------------------------------------------------
-- (e) View: v_low_stock
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id,
       medicine_name,
       unit_price,
       stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- ---------------------------------------------------------------------
-- (f) Index: one medicine's sales within a sold_on range
--     Equality column (medicine_id) first, range column (sold_on) second:
--     the B-tree jumps to the medicine and reads only the date range in order.
-- ---------------------------------------------------------------------
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_sales
--     Upsert = replace (never add to) the day's totals, so reruns are safe.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day must not be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date)
    DO UPDATE SET total_qty    = EXCLUDED.total_qty,
                  total_amount = EXCLUDED.total_amount;
END;
$$;

-- pg_cron must be installed and listed in shared_preload_libraries.
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every day at 00:15, for the previous day
SELECT cron.schedule(
    'pharmacy_refresh_sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$
);

-- =====================================================================
-- DEMONSTRATION / TESTING
-- =====================================================================

-- (a) Six valid sales loaded THROUGH the procedure
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(1,  5, CURRENT_DATE - 1);
CALL pr_record_sale(2,  8, CURRENT_DATE - 1);
CALL pr_record_sale(3,  5, CURRENT_DATE - 1);
CALL pr_record_sale(2,  4, CURRENT_DATE);
CALL pr_record_sale(1,  3, CURRENT_DATE);

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;       -- one row per stock change

-- (b) Function tests
SELECT fn_sale_value(1, 4) AS value_of_4_paracetamol;   -- 10.00
-- SELECT fn_sale_value(99, 1);   -- ERROR: Unknown medicine_id
-- SELECT fn_sale_value(1, 0);    -- ERROR: Invalid quantity

-- (c) Invalid sales leave both tables unchanged (uncomment one at a time)
-- CALL pr_record_sale(3, 500, CURRENT_DATE);   -- ERROR: Insufficient stock
-- CALL pr_record_sale(99, 1, CURRENT_DATE);    -- ERROR: Unknown medicine_id
-- CALL pr_record_sale(1, -2, CURRENT_DATE);    -- ERROR: Invalid quantity

-- (d) A price change does NOT touch stock_qty, so no audit row is written
UPDATE medicines SET unit_price = 2.50 WHERE medicine_id = 1;
SELECT COUNT(*) AS audit_rows FROM stock_audit;

-- (e) Query the view after a further sale
CALL pr_record_sale(2, 8, CURRENT_DATE);        -- Amoxicillin 20-8-4-8 = 0 left
SELECT * FROM v_low_stock ORDER BY medicine_id;

-- (f) EXPLAIN (seqscan disabled only because the demo table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Run the job manually twice: totals stay the same (no double counting)
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE);
SELECT * FROM daily_sales ORDER BY sales_date;

-- Inspect the scheduled job
SELECT jobid, jobname, schedule, command, active FROM cron.job;
