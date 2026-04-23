-- =========================================================
-- Reconcile: messages overwritten by status payloads
-- Target: MySQL 8.x / AWS RDS
--
-- Purpose:
--   Restore richer native message payloads from raw webhook history when
--   historical messages were overwritten by /status last_message payloads.
--
-- Scope:
--   - prefer native /incoming or /outgoing payload when messages.client_payload
--     currently contains only $.last_message
--   - recover a more specific attachment_type when native payload can determine it
--
-- Safety notes:
--   - this script is conservative: it only touches rows where a native raw event
--     exists and client_payload currently looks status-derived
--   - it does not modify delivery_status or delivery_status_at
-- =========================================================

-- =========================================================
-- 1) Preview outgoing messages currently overwritten by status payload
-- =========================================================

SELECT
    m.id,
    m.message_external_id,
    m.sender_type,
    m.attachment_type,
    JSON_EXTRACT(m.client_payload, '$.last_message') AS status_payload,
    r.received_at AS outgoing_received_at
FROM messages m
JOIN webhook_events_raw r
    ON r.provider_name = m.provider_name
   AND r.source_endpoint = 'outgoing'
   AND JSON_UNQUOTE(JSON_EXTRACT(r.raw_payload_json, '$._id_')) = m.message_external_id
WHERE JSON_EXTRACT(m.client_payload, '$.last_message') IS NOT NULL
ORDER BY m.id
LIMIT 100;

START TRANSACTION;

-- =========================================================
-- 2) Restore richer outgoing payloads
-- =========================================================

UPDATE messages m
JOIN (
    SELECT
        provider_name,
        JSON_UNQUOTE(JSON_EXTRACT(raw_payload_json, '$._id_')) AS message_external_id,
        raw_payload_json
    FROM webhook_events_raw
    WHERE source_endpoint = 'outgoing'
) native_outgoing
    ON native_outgoing.provider_name = m.provider_name
   AND native_outgoing.message_external_id = m.message_external_id
SET
    m.client_payload = JSON_OBJECT('outgoing_message', native_outgoing.raw_payload_json),
    m.attachment_type = CASE
        WHEN LOWER(COALESCE(m.attachment_type, '')) IN ('', 'attachment')
         AND JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.image')) IS NOT NULL THEN 'image'
        WHEN LOWER(COALESCE(m.attachment_type, '')) IN ('', 'attachment')
         AND JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.audio')) IS NOT NULL THEN 'audio'
        WHEN LOWER(COALESCE(m.attachment_type, '')) IN ('', 'attachment')
         AND (
             JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.file')) IS NOT NULL
             OR JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.fileUrl')) IS NOT NULL
         ) THEN 'file'
        ELSE m.attachment_type
    END,
    m.attachment_url = COALESCE(
        m.attachment_url,
        JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.image')),
        JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.audio')),
        JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.file')),
        JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.attachmentUrl')),
        JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.fileUrl')),
        JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.mediaUrl'))
    ),
    m.message_text = COALESCE(
        m.message_text,
        JSON_UNQUOTE(JSON_EXTRACT(native_outgoing.raw_payload_json, '$.message'))
    )
WHERE JSON_EXTRACT(m.client_payload, '$.last_message') IS NOT NULL;

SELECT ROW_COUNT() AS restored_outgoing_message_rows;

-- =========================================================
-- 3) Restore richer incoming payloads if such historical artifacts exist
-- =========================================================

UPDATE messages m
JOIN (
    SELECT
        provider_name,
        JSON_UNQUOTE(JSON_EXTRACT(raw_payload_json, '$._id_')) AS message_external_id,
        raw_payload_json
    FROM webhook_events_raw
    WHERE source_endpoint = 'incoming'
) native_incoming
    ON native_incoming.provider_name = m.provider_name
   AND native_incoming.message_external_id = m.message_external_id
SET
    m.client_payload = JSON_OBJECT('incoming_message', native_incoming.raw_payload_json),
    m.attachment_type = CASE
        WHEN LOWER(COALESCE(m.attachment_type, '')) IN ('', 'attachment')
         AND JSON_UNQUOTE(JSON_EXTRACT(native_incoming.raw_payload_json, '$.audio')) IS NOT NULL THEN 'audio'
        ELSE m.attachment_type
    END,
    m.attachment_url = COALESCE(
        m.attachment_url,
        JSON_UNQUOTE(JSON_EXTRACT(native_incoming.raw_payload_json, '$.audio')),
        JSON_UNQUOTE(JSON_EXTRACT(native_incoming.raw_payload_json, '$.attachmentUrl')),
        JSON_UNQUOTE(JSON_EXTRACT(native_incoming.raw_payload_json, '$.fileUrl')),
        JSON_UNQUOTE(JSON_EXTRACT(native_incoming.raw_payload_json, '$.mediaUrl'))
    ),
    m.message_text = COALESCE(
        m.message_text,
        JSON_UNQUOTE(JSON_EXTRACT(native_incoming.raw_payload_json, '$.message')),
        JSON_UNQUOTE(JSON_EXTRACT(native_incoming.raw_payload_json, '$.buttonName'))
    )
WHERE JSON_EXTRACT(m.client_payload, '$.last_message') IS NOT NULL;

SELECT ROW_COUNT() AS restored_incoming_message_rows;

COMMIT;

-- =========================================================
-- 4) Post-check
-- =========================================================

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
    ) AS outgoing_messages_still_status_overwritten,
    SUM(
        has_incoming_raw = 1
        AND has_status_raw = 1
        AND JSON_EXTRACT(m.client_payload, '$.last_message') IS NOT NULL
    ) AS incoming_messages_still_status_overwritten
FROM raw_message_endpoints rme
JOIN messages m
    ON m.message_external_id = rme.message_external_id;
