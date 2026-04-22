-- =========================================================
-- Grafana validation queries
-- Target: MySQL 8.x / AWS RDS
--
-- Purpose:
--   Validate the reconciled analytics layer against real loaded data.
--
-- How to use:
--   Run block by block after applying
--   database/migrations/20260422_grafana_analytics_reconciliation.sql.
-- =========================================================

-- =========================================================
-- 1) Current coverage of classification fields
-- =========================================================

SELECT
    COUNT(*) AS conversations_total,
    SUM(CASE WHEN topic IS NOT NULL THEN 1 ELSE 0 END) AS with_topic,
    SUM(CASE WHEN subtopic IS NOT NULL THEN 1 ELSE 0 END) AS with_subtopic,
    SUM(CASE WHEN product IS NOT NULL THEN 1 ELSE 0 END) AS with_product,
    SUM(CASE WHEN activity_name IS NOT NULL THEN 1 ELSE 0 END) AS with_activity_name,
    SUM(CASE WHEN motivo_consulta_aprox IS NOT NULL THEN 1 ELSE 0 END) AS with_motivo_consulta_aprox,
    SUM(CASE WHEN quote_generated_flag = 1 THEN 1 ELSE 0 END) AS with_quote_generated_flag
FROM vw_grafana_conversations_current;

SELECT
    classification_quality,
    motivo_consulta_source_aprox,
    activity_name_source,
    COUNT(*) AS conversation_count
FROM vw_grafana_conversations_current
GROUP BY
    classification_quality,
    motivo_consulta_source_aprox,
    activity_name_source
ORDER BY conversation_count DESC;

-- =========================================================
-- 2) Activity / product reconciliation audit
-- =========================================================

SELECT
    product_data_quality,
    COUNT(*) AS conversation_count
FROM vw_grafana_conversations_current
GROUP BY product_data_quality
ORDER BY conversation_count DESC;

SELECT
    conversation_id,
    conversation_external_id,
    product,
    activity_name,
    ap_actividad,
    motivo_consulta_aprox,
    product_data_quality,
    CHAR_LENGTH(product) AS product_length
FROM vw_grafana_conversations_current
WHERE product IS NOT NULL
ORDER BY
    product_data_quality,
    CHAR_LENGTH(product) DESC,
    conversation_id;

-- Long free-text values should be reviewed manually. This is an
-- explicit audit heuristic, not a production metric.
SELECT
    conversation_id,
    conversation_external_id,
    product,
    activity_name,
    motivo_consulta_aprox
FROM vw_grafana_conversations_current
WHERE product IS NOT NULL
  AND CHAR_LENGTH(product) > 40
ORDER BY CHAR_LENGTH(product) DESC;

-- =========================================================
-- 3) Resolution exactness vs support
-- =========================================================

SELECT
    resolution_data_quality,
    resolved_flag_source,
    COUNT(*) AS conversation_count
FROM vw_grafana_resolution_current
GROUP BY
    resolution_data_quality,
    resolved_flag_source
ORDER BY conversation_count DESC;

SELECT
    conversation_id,
    conversation_external_id,
    resolved_flag,
    resolved_flag_source,
    closed_at,
    closed_by,
    resolution_type,
    resolution_data_quality,
    timeline_quality
FROM vw_grafana_resolution_current
WHERE resolved_flag = 1
   OR closed_at IS NOT NULL
ORDER BY conversation_id;

SELECT
    COUNT(*) AS resolved_without_closed_at
FROM vw_grafana_resolution_current
WHERE resolved_flag = 1
  AND closed_at IS NULL;

-- =========================================================
-- 4) Handoff approximation audit
-- =========================================================

SELECT
    handoff_detection_basis_aprox,
    interaction_mode_observed,
    COUNT(*) AS conversation_count
FROM vw_grafana_handoff_to_human_aprox
GROUP BY
    handoff_detection_basis_aprox,
    interaction_mode_observed
ORDER BY conversation_count DESC;

SELECT
    provider_name,
    channel,
    current_queue_name,
    status_current,
    COUNT(*) AS handoff_conversations
FROM vw_grafana_handoff_to_human_aprox
GROUP BY
    provider_name,
    channel,
    current_queue_name,
    status_current
ORDER BY handoff_conversations DESC;

-- =========================================================
-- 5) Interaction mode audit
-- =========================================================

SELECT
    interaction_mode_observed,
    message_history_quality,
    COUNT(*) AS conversation_count,
    AVG(message_count_observed) AS avg_messages_observed
FROM vw_grafana_conversations_current
GROUP BY
    interaction_mode_observed,
    message_history_quality
ORDER BY conversation_count DESC;

SELECT
    conversation_id,
    conversation_external_id,
    interaction_mode_observed,
    message_count_user_observed,
    message_count_bot_observed,
    message_count_operator_observed,
    message_history_quality
FROM vw_grafana_conversations_current
ORDER BY
    message_history_quality DESC,
    message_count_observed ASC,
    conversation_id;

-- =========================================================
-- 6) Temporal consistency and outliers
-- =========================================================

SELECT
    timeline_quality,
    COUNT(*) AS conversation_count
FROM vw_grafana_conversations_current
GROUP BY timeline_quality
ORDER BY conversation_count DESC;

SELECT
    conversation_id,
    conversation_external_id,
    conversation_started_at,
    first_user_message_at,
    first_bot_response_at,
    first_human_response_at,
    last_message_at,
    closed_at,
    timeline_quality
FROM vw_grafana_conversations_current
WHERE timeline_quality <> 'ok'
ORDER BY conversation_id;

SELECT
    provider_name,
    channel,
    AVG(time_to_first_bot_response_seconds) AS avg_time_to_first_bot_response_seconds,
    MIN(time_to_first_bot_response_seconds) AS min_time_to_first_bot_response_seconds,
    MAX(time_to_first_bot_response_seconds) AS max_time_to_first_bot_response_seconds,
    AVG(time_to_first_human_response_seconds) AS avg_time_to_first_human_response_seconds,
    MIN(time_to_first_human_response_seconds) AS min_time_to_first_human_response_seconds,
    MAX(time_to_first_human_response_seconds) AS max_time_to_first_human_response_seconds
FROM vw_grafana_conversations_current
GROUP BY provider_name, channel;

-- =========================================================
-- 7) Queue, channel and status distribution
-- =========================================================

SELECT
    provider_name,
    channel,
    current_queue_name,
    status_current,
    COUNT(*) AS conversation_count,
    SUM(CASE WHEN is_bot_muted = 1 THEN 1 ELSE 0 END) AS bot_muted_count,
    SUM(CASE WHEN pending_message_count > 0 THEN 1 ELSE 0 END) AS pending_count
FROM vw_grafana_conversations_current
GROUP BY
    provider_name,
    channel,
    current_queue_name,
    status_current
ORDER BY conversation_count DESC;

-- =========================================================
-- 8) Intents and journey proxies
-- =========================================================

SELECT
    intent_name,
    COUNT(*) AS snapshot_occurrence_count,
    COUNT(DISTINCT conversation_id) AS distinct_conversation_count
FROM vw_grafana_executed_intents
GROUP BY intent_name
ORDER BY snapshot_occurrence_count DESC, distinct_conversation_count DESC
LIMIT 25;

WITH ranked_latest_intent AS (
    SELECT
        snapshot_id,
        conversation_id,
        intent_name,
        snapshot_at,
        ROW_NUMBER() OVER (
            PARTITION BY conversation_id
            ORDER BY snapshot_at DESC, snapshot_id DESC
        ) AS row_num
    FROM vw_grafana_executed_intents
)
SELECT
    rli.intent_name AS latest_intent_name_aprox,
    COUNT(*) AS conversation_count,
    SUM(CASE WHEN c.handoff_to_human_aprox = 1 THEN 1 ELSE 0 END) AS handoff_conversation_count_aprox,
    SUM(CASE WHEN c.resolved_flag = 1 THEN 1 ELSE 0 END) AS resolved_conversation_count
FROM ranked_latest_intent rli
JOIN vw_grafana_conversations_current c
  ON c.conversation_id = rli.conversation_id
WHERE rli.row_num = 1
GROUP BY rli.intent_name
ORDER BY conversation_count DESC, handoff_conversation_count_aprox DESC;

-- =========================================================
-- 9) Breakdown of motives / activities
-- =========================================================

SELECT
    provider_name,
    channel,
    queue_name,
    status_current,
    activity_name,
    activity_name_source,
    motivo_consulta_aprox,
    motivo_consulta_source_aprox,
    product,
    product_data_quality,
    conversation_count,
    handoff_to_human_count_aprox,
    resolved_count,
    quoted_conversation_count
FROM vw_grafana_activity_motive_breakdown_current
ORDER BY conversation_count DESC, quoted_conversation_count DESC, handoff_to_human_count_aprox DESC;

-- =========================================================
-- 10) Snapshot/context duplication audit
--
-- Duplicates are expected when delivered/read snapshots share the same
-- timestamp. These queries quantify the density to avoid double-counting
-- in ad hoc analysis.
-- =========================================================

SELECT
    conversation_id,
    snapshot_at,
    COUNT(*) AS duplicated_rows
FROM conversation_snapshots
GROUP BY conversation_id, snapshot_at
HAVING COUNT(*) > 1
ORDER BY duplicated_rows DESC, conversation_id, snapshot_at;

SELECT
    conversation_id,
    snapshot_at,
    COUNT(*) AS duplicated_rows
FROM conversation_contexts
GROUP BY conversation_id, snapshot_at
HAVING COUNT(*) > 1
ORDER BY duplicated_rows DESC, conversation_id, snapshot_at;

-- =========================================================
-- 11) Message quality and operator volume checks
-- =========================================================

SELECT
    sender_type,
    direction,
    COUNT(*) AS message_count,
    SUM(CASE WHEN message_text IS NULL OR message_text = '' THEN 1 ELSE 0 END) AS empty_text_count,
    SUM(CASE WHEN has_attachment = 1 THEN 1 ELSE 0 END) AS attachment_count
FROM messages
GROUP BY sender_type, direction
ORDER BY message_count DESC;

SELECT
    delivery_status,
    COUNT(*) AS message_count
FROM messages
GROUP BY delivery_status
ORDER BY message_count DESC;

SELECT
    operator_id,
    operator_external_id,
    operator_name,
    operator_email,
    SUM(outbound_message_count) AS outbound_message_count,
    SUM(conversation_count) AS conversation_count
FROM vw_grafana_operator_volume_from_messages
GROUP BY
    operator_id,
    operator_external_id,
    operator_name,
    operator_email
ORDER BY outbound_message_count DESC, conversation_count DESC;
