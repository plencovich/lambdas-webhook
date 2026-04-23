-- =========================================================
-- Reconcile: conversation_contexts cleanup
-- Target: MySQL 8.x / AWS RDS
--
-- Purpose:
--   1. remove sensitive / non-allowlisted keys from historical
--      conversation_contexts.context_json
--   2. remove exact duplicate context rows with the same snapshot_at
--
-- Important:
--   - this script does NOT delete consecutive unchanged contexts across
--     different timestamps; that remains a historical observation
--   - it only removes exact same-snapshot duplicates after sanitization
--   - allowlisted keys are aligned with the status mapper remediation
--
-- Suggested execution order:
--   1. review preview queries
--   2. run this script
--   3. if needed, run
--      database/query_packs/20260421_activity_product_reconciliation.sql
-- =========================================================

-- =========================================================
-- 1) Preview sensitive / removable keys still present in derived context
-- =========================================================

SELECT 'AP_User_Password' AS key_name, COUNT(*) AS occurrences
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_User_Password') IS NOT NULL
UNION ALL
SELECT 'AP_DNITomador', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_DNITomador') IS NOT NULL
UNION ALL
SELECT 'AP_User_Nombre', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_User_Nombre') IS NOT NULL
UNION ALL
SELECT 'AP_User_Apellido', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_User_Apellido') IS NOT NULL
UNION ALL
SELECT 'AP_User_Calle', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_User_Calle') IS NOT NULL
UNION ALL
SELECT 'AP_User_CP', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_User_CP') IS NOT NULL
UNION ALL
SELECT 'AP_MailTomador', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_MailTomador') IS NOT NULL;

-- =========================================================
-- 2) Preview exact duplicate rows by same snapshot_at and same content
-- =========================================================

SELECT
    conversation_id,
    snapshot_at,
    product,
    activity_name,
    quote_external_id,
    coverage_external_id,
    completion_message_text,
    COUNT(*) AS repeated_rows
FROM conversation_contexts
GROUP BY
    conversation_id,
    snapshot_at,
    product,
    topic,
    subtopic,
    quote_external_id,
    coverage_external_id,
    quoted_total_amount,
    quote_description,
    activity_name,
    completion_message_text,
    context_json
HAVING COUNT(*) > 1
ORDER BY repeated_rows DESC, conversation_id, snapshot_at;

START TRANSACTION;

-- =========================================================
-- 3) Sanitize historical context_json to the new allowlist
-- =========================================================

UPDATE conversation_contexts cc
JOIN (
    SELECT
        base.id,
        CASE
            WHEN JSON_LENGTH(base.sanitized_context_json) = 0 THEN NULL
            ELSE base.sanitized_context_json
        END AS sanitized_context_json
    FROM (
        SELECT
            cc_inner.id,
            JSON_MERGE_PATCH(
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.AP_Actividad') IS NOT NULL
                    THEN JSON_OBJECT('AP_Actividad', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.AP_Actividad')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.ActividadCode') IS NOT NULL
                    THEN JSON_OBJECT('ActividadCode', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.ActividadCode')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.ActividadName') IS NOT NULL
                    THEN JSON_OBJECT('ActividadName', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.ActividadName')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.BusquedaActividad') IS NOT NULL
                    THEN JSON_OBJECT('BusquedaActividad', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.BusquedaActividad')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.DeathAmount') IS NOT NULL
                    THEN JSON_OBJECT('DeathAmount', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.DeathAmount')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.IssueResuelto') IS NOT NULL
                    THEN JSON_OBJECT('IssueResuelto', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.IssueResuelto')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.PreguntarAccionCompleta') IS NOT NULL
                    THEN JSON_OBJECT('PreguntarAccionCompleta', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.PreguntarAccionCompleta')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.RespuestaAccionCompleta') IS NOT NULL
                    THEN JSON_OBJECT('RespuestaAccionCompleta', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.RespuestaAccionCompleta')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.typeDate') IS NOT NULL
                    THEN JSON_OBJECT('typeDate', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.typeDate')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.AP_Desde') IS NOT NULL
                    THEN JSON_OBJECT('AP_Desde', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.AP_Desde')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.AP_Hasta') IS NOT NULL
                    THEN JSON_OBJECT('AP_Hasta', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.AP_Hasta')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.AP_validity_start') IS NOT NULL
                    THEN JSON_OBJECT('AP_validity_start', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.AP_validity_start')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.AP_validity_end') IS NOT NULL
                    THEN JSON_OBJECT('AP_validity_end', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.AP_validity_end')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.AP_Price') IS NOT NULL
                    THEN JSON_OBJECT('AP_Price', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.AP_Price')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.AP_Price_Total') IS NOT NULL
                    THEN JSON_OBJECT('AP_Price_Total', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.AP_Price_Total')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.AP_QuoteId') IS NOT NULL
                    THEN JSON_OBJECT('AP_QuoteId', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.AP_QuoteId')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.AP_CoverageId') IS NOT NULL
                    THEN JSON_OBJECT('AP_CoverageId', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.AP_CoverageId')))
                    ELSE JSON_OBJECT()
                END,
                CASE
                    WHEN JSON_EXTRACT(cc_inner.context_json, '$.AP_Quote_Descrption') IS NOT NULL
                    THEN JSON_OBJECT('AP_Quote_Descrption', JSON_UNQUOTE(JSON_EXTRACT(cc_inner.context_json, '$.AP_Quote_Descrption')))
                    ELSE JSON_OBJECT()
                END
            ) AS sanitized_context_json
        FROM conversation_contexts cc_inner
        WHERE cc_inner.context_json IS NOT NULL
    ) base
) sanitized
    ON sanitized.id = cc.id
SET cc.context_json = sanitized.sanitized_context_json
WHERE COALESCE(CAST(cc.context_json AS CHAR(12000)), 'null')
   <> COALESCE(CAST(sanitized.sanitized_context_json AS CHAR(12000)), 'null');

SELECT ROW_COUNT() AS sanitized_context_rows;

-- =========================================================
-- 4) Delete exact duplicates after sanitization
-- =========================================================

DELETE cc
FROM conversation_contexts cc
JOIN (
    SELECT id
    FROM (
        SELECT
            id,
            ROW_NUMBER() OVER (
                PARTITION BY
                    conversation_id,
                    snapshot_at,
                    COALESCE(product, '__null__'),
                    COALESCE(topic, '__null__'),
                    COALESCE(subtopic, '__null__'),
                    COALESCE(quote_external_id, '__null__'),
                    COALESCE(coverage_external_id, '__null__'),
                    COALESCE(CAST(quoted_total_amount AS CHAR), '__null__'),
                    COALESCE(quote_description, '__null__'),
                    COALESCE(activity_name, '__null__'),
                    COALESCE(completion_message_text, '__null__'),
                    COALESCE(CAST(context_json AS CHAR(12000)), '__null__')
                ORDER BY id
            ) AS row_num
        FROM conversation_contexts
    ) ranked
    WHERE row_num > 1
) duplicate_rows
    ON duplicate_rows.id = cc.id;

SELECT ROW_COUNT() AS deleted_exact_duplicate_context_rows;

COMMIT;

-- =========================================================
-- 5) Post-check
-- =========================================================

SELECT 'AP_User_Password' AS key_name, COUNT(*) AS occurrences
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_User_Password') IS NOT NULL
UNION ALL
SELECT 'AP_DNITomador', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_DNITomador') IS NOT NULL
UNION ALL
SELECT 'AP_User_Nombre', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_User_Nombre') IS NOT NULL;

SELECT
    conversation_id,
    snapshot_at,
    COUNT(*) AS repeated_rows
FROM conversation_contexts
GROUP BY
    conversation_id,
    snapshot_at,
    product,
    topic,
    subtopic,
    quote_external_id,
    coverage_external_id,
    quoted_total_amount,
    quote_description,
    activity_name,
    completion_message_text,
    context_json
HAVING COUNT(*) > 1
ORDER BY repeated_rows DESC, conversation_id, snapshot_at;
