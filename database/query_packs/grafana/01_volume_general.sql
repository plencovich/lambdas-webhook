-- =========================================================
-- Grafana Panel 1: Volumen general
-- Notes:
--   - use with MySQL datasource
--   - $__timeFilter and $__timeGroupAlias are Grafana macros
-- =========================================================

-- Raw events by endpoint
SELECT
    $__timeGroupAlias(received_at, '1d'),
    source_endpoint,
    COUNT(*) AS raw_events
FROM webhook_events_raw
WHERE $__timeFilter(received_at)
GROUP BY 1, source_endpoint
ORDER BY 1, source_endpoint;

-- Conversations by start date
SELECT
    $__timeGroupAlias(conversation_started_at, '1d'),
    channel,
    COUNT(*) AS conversations
FROM conversations
WHERE conversation_started_at IS NOT NULL
  AND $__timeFilter(conversation_started_at)
GROUP BY 1, channel
ORDER BY 1, channel;

-- Messages by event time
SELECT
    $__timeGroupAlias(message_at, '1d'),
    direction,
    COUNT(*) AS messages
FROM messages
WHERE $__timeFilter(message_at)
GROUP BY 1, direction
ORDER BY 1, direction;
