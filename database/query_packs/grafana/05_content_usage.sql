-- =========================================================
-- Grafana Panel 5: Contenido y uso
-- =========================================================

-- Button usage
SELECT
    $__timeGroupAlias(message_at, '1d'),
    COUNT(*) AS button_messages,
    COUNT(DISTINCT conversation_id) AS conversations_with_buttons
FROM messages
WHERE is_button = 1
  AND $__timeFilter(message_at)
GROUP BY 1
ORDER BY 1;

-- Attachments by type
SELECT
    COALESCE(attachment_type, 'unknown') AS attachment_type,
    COUNT(*) AS messages
FROM messages
WHERE has_attachment = 1
  AND $__timeFilter(message_at)
GROUP BY attachment_type
ORDER BY messages DESC, attachment_type;

-- Current activity / motive breakdown
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

-- Quote / coverage signal
SELECT
    $__timeGroupAlias(COALESCE(conversation_started_at, last_message_at), '1d'),
    SUM(CASE WHEN quote_generated_flag = 1 THEN 1 ELSE 0 END) AS quoted_conversations,
    COUNT(*) AS conversations
FROM vw_grafana_conversations_current
WHERE $__timeFilter(COALESCE(conversation_started_at, last_message_at))
GROUP BY 1
ORDER BY 1;
