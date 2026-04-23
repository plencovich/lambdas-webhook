-- =========================================================
-- Grafana Panel 3: Tiempos operativos
-- Notes:
--   - exact only when timeline_quality = 'ok'
--   - resolution_time is not exposed because closed_at has no real coverage
-- =========================================================

-- Average first bot response
SELECT
    $__timeGroupAlias(COALESCE(first_user_message_at, conversation_started_at), '1d'),
    channel,
    AVG(time_to_first_bot_response_seconds) AS avg_time_to_first_bot_response_seconds
FROM vw_grafana_conversations_current
WHERE $__timeFilter(COALESCE(first_user_message_at, conversation_started_at))
  AND time_to_first_bot_response_seconds IS NOT NULL
  AND timeline_quality = 'ok'
GROUP BY 1, channel
ORDER BY 1, channel;

-- Average first human response
SELECT
    $__timeGroupAlias(COALESCE(first_user_message_at, conversation_started_at), '1d'),
    current_queue_name AS queue_name,
    AVG(time_to_first_human_response_seconds) AS avg_time_to_first_human_response_seconds
FROM vw_grafana_conversations_current
WHERE $__timeFilter(COALESCE(first_user_message_at, conversation_started_at))
  AND time_to_first_human_response_seconds IS NOT NULL
  AND timeline_quality = 'ok'
GROUP BY 1, queue_name
ORDER BY 1, queue_name;

-- Operational duration
SELECT
    $__timeGroupAlias(conversation_started_at, '1d'),
    current_queue_name AS queue_name,
    AVG(TIMESTAMPDIFF(SECOND, conversation_started_at, last_message_at)) AS avg_activity_seconds
FROM conversations
WHERE conversation_started_at IS NOT NULL
  AND last_message_at IS NOT NULL
  AND last_message_at >= conversation_started_at
  AND $__timeFilter(conversation_started_at)
GROUP BY 1, queue_name
ORDER BY 1, queue_name;

-- Timeline outliers table
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
