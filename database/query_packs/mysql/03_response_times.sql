-- =========================================================
-- MySQL Panel 3: Tiempos operativos
-- Parameters example:
--   SET @from_ts = '2026-04-21 00:00:00';
--   SET @to_ts   = '2026-04-24 23:59:59';
-- =========================================================

SELECT
    DATE(COALESCE(first_user_message_at, conversation_started_at)) AS metric_day,
    channel,
    AVG(time_to_first_bot_response_seconds) AS avg_time_to_first_bot_response_seconds
FROM vw_grafana_conversations_current
WHERE COALESCE(first_user_message_at, conversation_started_at) >= @from_ts
  AND COALESCE(first_user_message_at, conversation_started_at) < @to_ts
  AND time_to_first_bot_response_seconds IS NOT NULL
  AND timeline_quality = 'ok'
GROUP BY DATE(COALESCE(first_user_message_at, conversation_started_at)), channel
ORDER BY metric_day, channel;

SELECT
    DATE(COALESCE(first_user_message_at, conversation_started_at)) AS metric_day,
    current_queue_name AS queue_name,
    AVG(time_to_first_human_response_seconds) AS avg_time_to_first_human_response_seconds
FROM vw_grafana_conversations_current
WHERE COALESCE(first_user_message_at, conversation_started_at) >= @from_ts
  AND COALESCE(first_user_message_at, conversation_started_at) < @to_ts
  AND time_to_first_human_response_seconds IS NOT NULL
  AND timeline_quality = 'ok'
GROUP BY DATE(COALESCE(first_user_message_at, conversation_started_at)), current_queue_name
ORDER BY metric_day, queue_name;

SELECT
    DATE(conversation_started_at) AS metric_day,
    current_queue_name AS queue_name,
    AVG(TIMESTAMPDIFF(SECOND, conversation_started_at, last_message_at)) AS avg_activity_seconds
FROM conversations
WHERE conversation_started_at IS NOT NULL
  AND last_message_at IS NOT NULL
  AND last_message_at >= conversation_started_at
  AND conversation_started_at >= @from_ts
  AND conversation_started_at < @to_ts
GROUP BY DATE(conversation_started_at), current_queue_name
ORDER BY metric_day, queue_name;

SELECT
    conversation_id,
    conversation_external_id,
    timeline_quality,
    first_user_message_at,
    first_bot_response_at,
    first_human_response_at,
    last_message_at
FROM vw_grafana_conversations_current
WHERE timeline_quality <> 'ok'
ORDER BY conversation_id;
