-- =========================================================
-- MySQL Panel 5: Contenido y uso
-- Parameters example:
--   SET @from_ts = '2026-04-21 00:00:00';
--   SET @to_ts   = '2026-04-24 23:59:59';
-- =========================================================

SELECT
    DATE(message_at) AS message_day,
    COUNT(*) AS button_messages,
    COUNT(DISTINCT conversation_id) AS conversations_with_buttons
FROM messages
WHERE is_button = 1
  AND message_at >= @from_ts
  AND message_at < @to_ts
GROUP BY DATE(message_at)
ORDER BY message_day;

SELECT
    COALESCE(attachment_type, 'unknown') AS attachment_type,
    COUNT(*) AS messages
FROM messages
WHERE has_attachment = 1
  AND message_at >= @from_ts
  AND message_at < @to_ts
GROUP BY COALESCE(attachment_type, 'unknown')
ORDER BY messages DESC, attachment_type;

SELECT
    motivo_consulta_aprox,
    motivo_consulta_source_aprox,
    activity_name,
    COUNT(*) AS conversations
FROM vw_grafana_conversations_current
WHERE motivo_consulta_aprox IS NOT NULL
GROUP BY motivo_consulta_aprox, motivo_consulta_source_aprox, activity_name
ORDER BY conversations DESC
LIMIT 25;

SELECT
    DATE(COALESCE(conversation_started_at, last_message_at)) AS metric_day,
    SUM(CASE WHEN quote_generated_flag = 1 THEN 1 ELSE 0 END) AS quoted_conversations,
    COUNT(*) AS conversations
FROM vw_grafana_conversations_current
WHERE COALESCE(conversation_started_at, last_message_at) >= @from_ts
  AND COALESCE(conversation_started_at, last_message_at) < @to_ts
GROUP BY DATE(COALESCE(conversation_started_at, last_message_at))
ORDER BY metric_day;
