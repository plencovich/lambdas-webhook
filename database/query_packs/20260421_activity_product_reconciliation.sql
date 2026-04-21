-- =========================================================
-- Activity / product reconciliation
-- Target: MySQL 8.x / AWS RDS
--
-- Purpose:
--   Fix historical rows loaded before the mapper stopped using
--   AP_Actividad as fallback for product.
--
-- Scope:
--   - conversation_contexts.activity_name
--   - conversation_contexts.product
--   - conversations.product
--
-- Safety notes:
--   - Review the preview queries before running the UPDATE blocks.
--   - This script is intentionally conservative:
--       * it only nullifies product when product matches the
--         observed activity value
--       * it keeps product when it differs from activity_name
-- =========================================================

-- =========================================================
-- 1) Preview candidate rows in conversation_contexts
-- Expected:
--   - rows where product mirrors AP_Actividad or activity_name
--   - those rows should be reclassified as activity_name, not product
-- =========================================================

SELECT
    cc.id,
    cc.conversation_id,
    cc.snapshot_at,
    cc.product,
    cc.activity_name,
    JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.AP_Actividad')) AS ap_actividad,
    JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.BusquedaActividad')) AS busqueda_actividad
FROM conversation_contexts cc
WHERE cc.product IS NOT NULL
  AND cc.product <> ''
  AND LOWER(TRIM(cc.product)) = LOWER(
      TRIM(
          COALESCE(
              cc.activity_name,
              JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.AP_Actividad'))
          )
      )
  )
ORDER BY cc.snapshot_at DESC, cc.id DESC;

-- =========================================================
-- 2) Preview candidate rows in conversations
-- Expected:
--   - rows where current conversations.product mirrors the latest
--     activity_name / AP_Actividad from conversation_contexts
-- =========================================================

WITH latest_context AS (
    SELECT
        ranked.conversation_id,
        ranked.product,
        ranked.activity_name,
        ranked.context_json
    FROM (
        SELECT
            cc.*,
            ROW_NUMBER() OVER (
                PARTITION BY cc.conversation_id
                ORDER BY cc.snapshot_at DESC, cc.id DESC
            ) AS rn
        FROM conversation_contexts cc
    ) ranked
    WHERE ranked.rn = 1
)
SELECT
    c.id,
    c.conversation_external_id,
    c.product AS conversation_product,
    lc.product AS latest_context_product,
    lc.activity_name AS latest_activity_name,
    JSON_UNQUOTE(JSON_EXTRACT(lc.context_json, '$.AP_Actividad')) AS latest_ap_actividad
FROM conversations c
JOIN latest_context lc ON lc.conversation_id = c.id
WHERE c.product IS NOT NULL
  AND c.product <> ''
  AND LOWER(TRIM(c.product)) = LOWER(
      TRIM(
          COALESCE(
              lc.activity_name,
              JSON_UNQUOTE(JSON_EXTRACT(lc.context_json, '$.AP_Actividad'))
          )
      )
  )
ORDER BY c.id DESC;

-- =========================================================
-- 3) Reconcile conversation_contexts
-- Effect:
--   - backfills activity_name from AP_Actividad when missing
--   - clears product when it is just a copy of activity_name/AP_Actividad
-- =========================================================

START TRANSACTION;

UPDATE conversation_contexts cc
SET
    cc.activity_name = COALESCE(
        cc.activity_name,
        JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.AP_Actividad'))
    ),
    cc.product = CASE
        WHEN cc.product IS NOT NULL
         AND cc.product <> ''
         AND LOWER(TRIM(cc.product)) = LOWER(
             TRIM(
                 COALESCE(
                     cc.activity_name,
                     JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.AP_Actividad'))
                 )
             )
         )
        THEN NULL
        ELSE cc.product
    END
WHERE JSON_EXTRACT(cc.context_json, '$.AP_Actividad') IS NOT NULL;

-- Review before COMMIT.
SELECT ROW_COUNT() AS updated_context_rows;

-- =========================================================
-- 4) Reconcile conversations using latest context
-- Effect:
--   - clears conversations.product when it is only mirroring the
--     latest activity value
-- =========================================================

WITH latest_context AS (
    SELECT
        ranked.conversation_id,
        ranked.activity_name,
        ranked.context_json
    FROM (
        SELECT
            cc.*,
            ROW_NUMBER() OVER (
                PARTITION BY cc.conversation_id
                ORDER BY cc.snapshot_at DESC, cc.id DESC
            ) AS rn
        FROM conversation_contexts cc
    ) ranked
    WHERE ranked.rn = 1
)
UPDATE conversations c
JOIN latest_context lc ON lc.conversation_id = c.id
SET c.product = NULL
WHERE c.product IS NOT NULL
  AND c.product <> ''
  AND LOWER(TRIM(c.product)) = LOWER(
      TRIM(
          COALESCE(
              lc.activity_name,
              JSON_UNQUOTE(JSON_EXTRACT(lc.context_json, '$.AP_Actividad'))
          )
      )
  );

-- Review before COMMIT.
SELECT ROW_COUNT() AS updated_conversation_rows;

COMMIT;

-- =========================================================
-- 5) Post-check
-- =========================================================

SELECT
    COUNT(*) AS contexts_with_product_after_fix,
    SUM(CASE WHEN activity_name IS NOT NULL AND activity_name <> '' THEN 1 ELSE 0 END) AS contexts_with_activity_name_after_fix
FROM conversation_contexts;

SELECT
    COUNT(*) AS conversations_with_product_after_fix
FROM conversations
WHERE product IS NOT NULL
  AND product <> '';
