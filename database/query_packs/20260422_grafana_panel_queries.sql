-- =========================================================
-- Grafana panel queries
-- Target: MySQL 8.x / AWS RDS
--
-- Notes:
--   - these queries assume the reconciled 20260422 views exist
--   - titles/descriptions in Grafana should preserve exact vs aprox
--   - use $__timeFilter only inside Grafana
-- =========================================================

-- =========================================================
-- 1) Current conversations by channel / status / queue
-- =========================================================

SELECT
    channel,
    current_queue_name AS queue_name,
    status_current,
    COUNT(*) AS conversation_count
FROM vw_grafana_conversations_current
GROUP BY
    channel,
    current_queue_name,
    status_current
ORDER BY conversation_count DESC;

-- =========================================================
-- 2) Daily conversation volume
-- =========================================================

SELECT
    TIMESTAMP(conversation_date) AS time,
    channel,
    status_current,
    queue_name,
    SUM(conversation_count) AS conversation_count
FROM vw_grafana_conversations_daily
WHERE $__timeFilter(TIMESTAMP(conversation_date))
GROUP BY
    conversation_date,
    channel,
    status_current,
    queue_name
ORDER BY conversation_date, channel, status_current, queue_name;

-- =========================================================
-- 3) Handoff rate (approx)
-- =========================================================

SELECT
    channel,
    current_queue_name AS queue_name,
    COUNT(*) AS conversations_total,
    SUM(CASE WHEN handoff_to_human_aprox = 1 THEN 1 ELSE 0 END) AS handoff_conversations_aprox,
    ROUND(
        100 * SUM(CASE WHEN handoff_to_human_aprox = 1 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0),
        2
    ) AS handoff_rate_pct_aprox
FROM vw_grafana_conversations_current
GROUP BY
    channel,
    current_queue_name
ORDER BY handoff_rate_pct_aprox DESC, conversations_total DESC;

-- =========================================================
-- 4) Bot-only vs human-only vs mixed
-- =========================================================

SELECT
    interaction_mode_observed,
    COUNT(*) AS conversation_count
FROM vw_grafana_conversations_current
GROUP BY interaction_mode_observed
ORDER BY conversation_count DESC;

-- =========================================================
-- 5) Most frequent motives / activities
-- =========================================================

SELECT
    motivo_consulta_aprox,
    motivo_consulta_source_aprox,
    activity_name,
    activity_name_source,
    SUM(conversation_count) AS conversation_count,
    SUM(handoff_to_human_count_aprox) AS handoff_to_human_count_aprox,
    SUM(resolved_count) AS resolved_count,
    SUM(quoted_conversation_count) AS quoted_conversation_count
FROM vw_grafana_activity_motive_breakdown_current
GROUP BY
    motivo_consulta_aprox,
    motivo_consulta_source_aprox,
    activity_name,
    activity_name_source
ORDER BY conversation_count DESC, quoted_conversation_count DESC
LIMIT 20;

-- =========================================================
-- 6) Most frequent intents
-- =========================================================

SELECT
    intent_name,
    SUM(intent_occurrence_count) AS intent_occurrence_count,
    SUM(conversation_count) AS conversation_count
FROM vw_grafana_intents_daily
WHERE $__timeFilter(TIMESTAMP(intent_date))
GROUP BY intent_name
ORDER BY intent_occurrence_count DESC, conversation_count DESC
LIMIT 20;

-- =========================================================
-- 7) Operator volume from messages
-- =========================================================

SELECT
    TIMESTAMP(message_date) AS time,
    operator_name,
    operator_email,
    SUM(outbound_message_count) AS outbound_message_count,
    SUM(conversation_count) AS conversation_count
FROM vw_grafana_operator_volume_from_messages
WHERE $__timeFilter(TIMESTAMP(message_date))
GROUP BY
    message_date,
    operator_name,
    operator_email
ORDER BY message_date, outbound_message_count DESC;

-- =========================================================
-- 8) Time to first human response
--
-- Exact only when first_user_message_at exists and timeline quality is ok.
-- =========================================================

SELECT
    TIMESTAMP(DATE(COALESCE(conversation_started_at, first_human_response_at))) AS time,
    channel,
    current_queue_name AS queue_name,
    AVG(time_to_first_human_response_seconds) AS avg_time_to_first_human_response_seconds,
    MIN(time_to_first_human_response_seconds) AS min_time_to_first_human_response_seconds,
    MAX(time_to_first_human_response_seconds) AS max_time_to_first_human_response_seconds
FROM vw_grafana_conversations_current
WHERE $__timeFilter(COALESCE(conversation_started_at, first_human_response_at))
  AND time_to_first_human_response_seconds IS NOT NULL
  AND timeline_quality = 'ok'
GROUP BY
    DATE(COALESCE(conversation_started_at, first_human_response_at)),
    channel,
    current_queue_name
ORDER BY time, channel, queue_name;

-- =========================================================
-- 9) Resolved vs unresolved support
--
-- Important:
--   resolved_flag only reflects explicit IssueResuelto support.
--   Rows in resolution_not_supported are not unresolved conversations.
-- =========================================================

SELECT
    CASE
        WHEN resolved_flag = 1 THEN 'resolved_explicit'
        WHEN resolved_flag = 0 THEN 'not_resolved_explicit'
        ELSE 'resolution_not_supported'
    END AS resolution_bucket,
    resolution_data_quality,
    COUNT(*) AS conversation_count
FROM vw_grafana_resolution_current
GROUP BY
    resolution_bucket,
    resolution_data_quality
ORDER BY conversation_count DESC;

-- =========================================================
-- 10) Current journeys / latest intent proxy
--
-- This is approximate. It uses the most recent executed intent seen in
-- status snapshots as a proxy for current journey.
-- =========================================================

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
    SUM(CASE WHEN c.resolved_flag = 1 THEN 1 ELSE 0 END) AS resolved_conversation_count,
    SUM(CASE WHEN c.quote_generated_flag = 1 THEN 1 ELSE 0 END) AS quoted_conversation_count
FROM ranked_latest_intent rli
JOIN vw_grafana_conversations_current c
  ON c.conversation_id = rli.conversation_id
WHERE rli.row_num = 1
GROUP BY rli.intent_name
ORDER BY conversation_count DESC, handoff_conversation_count_aprox DESC;
