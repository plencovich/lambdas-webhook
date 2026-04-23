-- =========================================================
-- MySQL Panel 2: Actores e intervención
-- Parameters example:
--   SET @from_ts = '2026-04-21 00:00:00';
--   SET @to_ts   = '2026-04-24 23:59:59';
-- =========================================================

SELECT
    DATE(message_at) AS message_day,
    sender_type,
    COUNT(*) AS messages
FROM messages
WHERE message_at >= @from_ts
  AND message_at < @to_ts
GROUP BY DATE(message_at), sender_type
ORDER BY message_day, sender_type;

SELECT
    interaction_mode_observed,
    COUNT(*) AS conversations
FROM vw_grafana_conversations_current
GROUP BY interaction_mode_observed
ORDER BY conversations DESC;

SELECT
    current_queue_name AS queue_name,
    COUNT(*) AS conversations_total,
    SUM(CASE WHEN handoff_to_human_aprox = 1 THEN 1 ELSE 0 END) AS handoff_conversations_aprox,
    ROUND(
        100 * SUM(CASE WHEN handoff_to_human_aprox = 1 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0),
        2
    ) AS handoff_rate_pct_aprox
FROM vw_grafana_conversations_current
GROUP BY current_queue_name
ORDER BY handoff_rate_pct_aprox DESC, conversations_total DESC;
