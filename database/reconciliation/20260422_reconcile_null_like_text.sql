-- =========================================================
-- Reconcile: null-like strings in customer attributes
-- Target: MySQL 8.x / AWS RDS
--
-- Purpose:
--   Normalize historical strings such as 'null', 'none', 'undefined'
--   into real SQL NULLs for customer attributes.
--
-- Safety notes:
--   - conservative scope: only customers table attributes with clear null-like semantics
--   - does not touch free-text conversational content
-- =========================================================

-- Preview
SELECT
    id,
    customer_external_id,
    customer_first_name,
    customer_last_name,
    customer_locale,
    customer_gender
FROM customers
WHERE LOWER(TRIM(COALESCE(customer_first_name, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
   OR LOWER(TRIM(COALESCE(customer_last_name, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
   OR LOWER(TRIM(COALESCE(customer_locale, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
   OR LOWER(TRIM(COALESCE(customer_gender, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
ORDER BY id;

START TRANSACTION;

UPDATE customers
SET
    customer_first_name = CASE
        WHEN LOWER(TRIM(COALESCE(customer_first_name, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
        THEN NULL ELSE customer_first_name
    END,
    customer_last_name = CASE
        WHEN LOWER(TRIM(COALESCE(customer_last_name, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
        THEN NULL ELSE customer_last_name
    END,
    customer_locale = CASE
        WHEN LOWER(TRIM(COALESCE(customer_locale, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
        THEN NULL ELSE customer_locale
    END,
    customer_gender = CASE
        WHEN LOWER(TRIM(COALESCE(customer_gender, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
        THEN NULL ELSE customer_gender
    END
WHERE LOWER(TRIM(COALESCE(customer_first_name, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
   OR LOWER(TRIM(COALESCE(customer_last_name, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
   OR LOWER(TRIM(COALESCE(customer_locale, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
   OR LOWER(TRIM(COALESCE(customer_gender, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na');

SELECT ROW_COUNT() AS updated_customer_rows;

COMMIT;

-- Post-check
SELECT
    COUNT(*) AS remaining_null_like_values
FROM customers
WHERE LOWER(TRIM(COALESCE(customer_first_name, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
   OR LOWER(TRIM(COALESCE(customer_last_name, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
   OR LOWER(TRIM(COALESCE(customer_locale, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na')
   OR LOWER(TRIM(COALESCE(customer_gender, ''))) IN ('null', 'none', 'undefined', 'n/a', 'na');
