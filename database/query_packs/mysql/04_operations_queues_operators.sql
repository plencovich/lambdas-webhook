-- =========================================================
-- MySQL Panel 4: Operación / colas / operadores
-- Parameters example:
--   SET @from_ts = '2026-04-21 00:00:00';
--   SET @to_ts   = '2026-04-24 23:59:59';
-- =========================================================

SELECT
    channel,
    current_queue_name AS queue_name,
    status_current,
    COUNT(*) AS conversations
FROM vw_grafana_conversations_current
GROUP BY channel, current_queue_name, status_current
ORDER BY conversations DESC;

SELECT
    DATE(message_at) AS message_day,
    COALESCE(queue_name, 'unknown') AS queue_name,
    sender_type,
    COUNT(*) AS messages
FROM messages
WHERE message_at >= @from_ts
  AND message_at < @to_ts
GROUP BY DATE(message_at), COALESCE(queue_name, 'unknown'), sender_type
ORDER BY message_day, queue_name, sender_type;

SELECT
    DATE(message_at) AS message_day,
    COALESCE(o.operator_name, m.sender_name, 'unknown') AS operator_name,
    COUNT(*) AS operator_messages,
    COUNT(DISTINCT m.conversation_id) AS conversations_touched
FROM messages m
LEFT JOIN operators o
    ON o.id = m.operator_id
WHERE m.sender_type = 'operator'
  AND m.message_at >= @from_ts
  AND m.message_at < @to_ts
GROUP BY DATE(message_at), COALESCE(o.operator_name, m.sender_name, 'unknown')
ORDER BY message_day, operator_messages DESC;
