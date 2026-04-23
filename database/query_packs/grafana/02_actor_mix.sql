-- =========================================================
-- Grafana Panel 2: Actores e intervención
-- =========================================================

-- Messages by sender type
SELECT
    $__timeGroupAlias(message_at, '1d'),
    sender_type,
    COUNT(*) AS messages
FROM messages
WHERE $__timeFilter(message_at)
GROUP BY 1, sender_type
ORDER BY 1, sender_type;

-- Conversations by observed interaction mode
SELECT
    interaction_mode_observed,
    COUNT(*) AS conversations
FROM vw_grafana_conversations_current
GROUP BY interaction_mode_observed
ORDER BY conversations DESC;

-- Approximate handoff rate
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
