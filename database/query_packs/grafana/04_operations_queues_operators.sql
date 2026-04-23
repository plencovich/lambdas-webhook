-- =========================================================
-- Grafana Panel 4: Operación / colas / operadores
-- =========================================================

-- Current conversations by queue and status
SELECT
    channel,
    current_queue_name AS queue_name,
    status_current,
    COUNT(*) AS conversations
FROM vw_grafana_conversations_current
GROUP BY channel, current_queue_name, status_current
ORDER BY conversations DESC;

-- Message traffic by queue and actor
SELECT
    $__timeGroupAlias(message_at, '1d'),
    COALESCE(queue_name, 'unknown') AS queue_name,
    sender_type,
    COUNT(*) AS messages
FROM messages
WHERE $__timeFilter(message_at)
GROUP BY 1, queue_name, sender_type
ORDER BY 1, queue_name, sender_type;

-- Operator message volume
SELECT
    $__timeGroupAlias(message_at, '1d'),
    COALESCE(o.operator_name, m.sender_name, 'unknown') AS operator_name,
    COUNT(*) AS operator_messages,
    COUNT(DISTINCT m.conversation_id) AS conversations_touched
FROM messages m
LEFT JOIN operators o
    ON o.id = m.operator_id
WHERE m.sender_type = 'operator'
  AND $__timeFilter(message_at)
GROUP BY 1, operator_name
ORDER BY 1, operator_messages DESC;
