-- =========================================================
-- Grafana Panel 6: Calidad y auditoría
-- Notes:
--   - several metrics here are intended for table/pie panels, not KPI cards
-- =========================================================

-- Coverage of key dimensions
SELECT
    COUNT(*) AS conversations,
    SUM(activity_name IS NOT NULL) AS with_activity_name,
    SUM(product IS NOT NULL) AS with_product,
    SUM(topic IS NOT NULL) AS with_topic,
    SUM(subtopic IS NOT NULL) AS with_subtopic,
    SUM(resolved_flag IS NOT NULL) AS with_resolved_flag
FROM vw_grafana_conversations_current;

-- Timeline quality buckets
SELECT
    timeline_quality,
    COUNT(*) AS conversations
FROM vw_grafana_conversations_current
GROUP BY timeline_quality
ORDER BY conversations DESC;

-- Exact duplicate contexts by same snapshot
SELECT
    conversation_id,
    snapshot_at,
    COUNT(*) AS repeated_rows
FROM conversation_contexts
GROUP BY
    conversation_id,
    snapshot_at,
    product,
    topic,
    subtopic,
    quote_external_id,
    coverage_external_id,
    quoted_total_amount,
    quote_description,
    activity_name,
    completion_message_text,
    context_json
HAVING COUNT(*) > 1
ORDER BY repeated_rows DESC, conversation_id, snapshot_at;

-- Messages still overwritten by status payload
WITH raw_message_endpoints AS (
    SELECT
        CASE
            WHEN source_endpoint = 'status'
                THEN JSON_UNQUOTE(JSON_EXTRACT(raw_payload_json, '$.LAST_MESSAGE._id_'))
            ELSE JSON_UNQUOTE(JSON_EXTRACT(raw_payload_json, '$._id_'))
        END AS message_external_id,
        MAX(source_endpoint = 'incoming') AS has_incoming_raw,
        MAX(source_endpoint = 'outgoing') AS has_outgoing_raw,
        MAX(source_endpoint = 'status') AS has_status_raw
    FROM webhook_events_raw
    GROUP BY
        CASE
            WHEN source_endpoint = 'status'
                THEN JSON_UNQUOTE(JSON_EXTRACT(raw_payload_json, '$.LAST_MESSAGE._id_'))
            ELSE JSON_UNQUOTE(JSON_EXTRACT(raw_payload_json, '$._id_'))
        END
)
SELECT
    SUM(
        has_outgoing_raw = 1
        AND has_status_raw = 1
        AND JSON_EXTRACT(m.client_payload, '$.last_message') IS NOT NULL
    ) AS outgoing_messages_overwritten_by_status_payload,
    SUM(
        has_incoming_raw = 1
        AND has_status_raw = 1
        AND JSON_EXTRACT(m.client_payload, '$.last_message') IS NOT NULL
    ) AS incoming_messages_overwritten_by_status_payload
FROM raw_message_endpoints rme
JOIN messages m
    ON m.message_external_id = rme.message_external_id;
