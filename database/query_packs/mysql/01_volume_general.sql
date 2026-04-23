-- =========================================================
-- MySQL Panel 1: Volumen general
-- Parameters example:
--   SET @from_ts = '2026-04-21 00:00:00';
--   SET @to_ts   = '2026-04-24 23:59:59';
-- =========================================================

SELECT
    DATE(received_at) AS event_day,
    source_endpoint,
    COUNT(*) AS raw_events
FROM webhook_events_raw
WHERE received_at >= @from_ts
  AND received_at < @to_ts
GROUP BY DATE(received_at), source_endpoint
ORDER BY event_day, source_endpoint;

SELECT
    DATE(conversation_started_at) AS conversation_day,
    channel,
    COUNT(*) AS conversations
FROM conversations
WHERE conversation_started_at IS NOT NULL
  AND conversation_started_at >= @from_ts
  AND conversation_started_at < @to_ts
GROUP BY DATE(conversation_started_at), channel
ORDER BY conversation_day, channel;

SELECT
    DATE(message_at) AS message_day,
    direction,
    COUNT(*) AS messages
FROM messages
WHERE message_at >= @from_ts
  AND message_at < @to_ts
GROUP BY DATE(message_at), direction
ORDER BY message_day, direction;
