-- =========================================================
-- Post-load audit pack
-- Target: MySQL 8.x / AWS RDS
--
-- Purpose:
--   Validate real data quality after loading webhook data from
--   /incoming, /outgoing and /status before enabling dashboards.
--
-- How to use:
--   Run block by block in MySQL Workbench or your SQL client.
--   Review results and compare against the interpretation notes.
-- =========================================================

-- =========================================================
-- 1) RAW INGESTION AND IDEMPOTENCY
-- Expected:
--   - No duplicate external_event_key rows
--   - No duplicate message_external_id rows
--   - endpoint volumes should be plausible
-- =========================================================

-- 1.1 Duplicate raw events by provider/event key
SELECT
    provider_name,
    external_event_key,
    COUNT(*) AS dup_count
FROM webhook_events_raw
GROUP BY provider_name, external_event_key
HAVING COUNT(*) > 1
ORDER BY dup_count DESC;

-- 1.2 Duplicate normalized messages
SELECT
    provider_name,
    message_external_id,
    COUNT(*) AS dup_count
FROM messages
GROUP BY provider_name, message_external_id
HAVING COUNT(*) > 1
ORDER BY dup_count DESC;

-- 1.3 Raw coverage by endpoint
SELECT
    source_endpoint,
    COUNT(*) AS raw_rows,
    COUNT(DISTINCT conversation_external_id) AS distinct_conversations,
    COUNT(DISTINCT customer_external_id) AS distinct_customers
FROM webhook_events_raw
GROUP BY source_endpoint
ORDER BY source_endpoint;

-- 1.4 Real status/sender combinations from /status
SELECT
    JSON_UNQUOTE(JSON_EXTRACT(raw_payload_json, '$.STATUS')) AS status_value,
    JSON_UNQUOTE(JSON_EXTRACT(raw_payload_json, '$.LAST_MESSAGE.from')) AS last_message_from,
    COUNT(*) AS cnt
FROM webhook_events_raw
WHERE source_endpoint = 'status'
GROUP BY
    JSON_UNQUOTE(JSON_EXTRACT(raw_payload_json, '$.STATUS')),
    JSON_UNQUOTE(JSON_EXTRACT(raw_payload_json, '$.LAST_MESSAGE.from'))
ORDER BY cnt DESC;

-- =========================================================
-- 2) RELATIONAL INTEGRITY
-- Expected:
--   - All counts should be zero
-- =========================================================

SELECT COUNT(*) AS orphan_messages_without_conversation
FROM messages m
LEFT JOIN conversations c ON c.id = m.conversation_id
WHERE c.id IS NULL;

SELECT COUNT(*) AS orphan_messages_without_customer
FROM messages m
LEFT JOIN customers c ON c.id = m.customer_id
WHERE c.id IS NULL;

SELECT COUNT(*) AS orphan_snapshots_without_conversation
FROM conversation_snapshots s
LEFT JOIN conversations c ON c.id = s.conversation_id
WHERE c.id IS NULL;

SELECT COUNT(*) AS orphan_contexts_without_conversation
FROM conversation_contexts cc
LEFT JOIN conversations c ON c.id = cc.conversation_id
WHERE c.id IS NULL;

-- =========================================================
-- 3) CURRENT CONVERSATION VS LATEST SNAPSHOT
-- Expected:
--   - Ideally zero rows
--   - If rows exist, /status is not fully reconciling current state
-- =========================================================

WITH latest_snapshot AS (
    SELECT
        cs.*,
        ROW_NUMBER() OVER (
            PARTITION BY cs.conversation_id
            ORDER BY cs.snapshot_at DESC, cs.id DESC
        ) AS rn
    FROM conversation_snapshots cs
)
SELECT
    c.id AS conversation_id,
    c.conversation_external_id,
    c.status_current AS conversation_status,
    ls.status_current AS latest_snapshot_status,
    c.current_queue_name AS conversation_queue,
    ls.queue_name AS latest_snapshot_queue,
    c.is_bot_muted AS conversation_bot_muted,
    ls.is_bot_muted AS latest_snapshot_bot_muted,
    c.pending_message_count AS conversation_pending,
    ls.pending_message_count AS latest_snapshot_pending,
    c.last_message_at AS conversation_last_message_at,
    ls.last_message_at AS latest_snapshot_last_message_at
FROM conversations c
JOIN latest_snapshot ls
    ON ls.conversation_id = c.id
   AND ls.rn = 1
WHERE
    COALESCE(c.status_current, '') <> COALESCE(ls.status_current, '')
 OR COALESCE(c.current_queue_name, '') <> COALESCE(ls.queue_name, '')
 OR COALESCE(c.is_bot_muted, 0) <> COALESCE(ls.is_bot_muted, 0)
 OR COALESCE(c.pending_message_count, 0) <> COALESCE(ls.pending_message_count, 0)
ORDER BY c.id;

-- =========================================================
-- 4) MESSAGE COVERAGE AND ACTOR MIX
-- Interpretation:
--   - message_count_* is exact only if /incoming and /outgoing are complete
--   - bot messages observed only through /status should be treated as observed
-- =========================================================

-- 4.1 Sender/direction mix
SELECT
    sender_type,
    direction,
    COUNT(*) AS message_count
FROM messages
GROUP BY sender_type, direction
ORDER BY message_count DESC;

-- 4.2 Delivery status coverage
SELECT
    COALESCE(delivery_status, 'NULL') AS delivery_status,
    COUNT(*) AS cnt
FROM messages
GROUP BY COALESCE(delivery_status, 'NULL')
ORDER BY cnt DESC;

-- 4.3 Operator linkage quality
SELECT
    CASE WHEN operator_id IS NULL THEN 'operator_missing' ELSE 'operator_linked' END AS operator_link_state,
    COUNT(*) AS cnt
FROM messages
WHERE sender_type = 'operator'
GROUP BY CASE WHEN operator_id IS NULL THEN 'operator_missing' ELSE 'operator_linked' END;

-- 4.4 Per-conversation message coverage
SELECT
    c.id,
    c.conversation_external_id,
    COUNT(m.id) AS total_messages,
    SUM(CASE WHEN m.sender_type = 'customer' THEN 1 ELSE 0 END) AS customer_messages,
    SUM(CASE WHEN m.sender_type = 'bot' THEN 1 ELSE 0 END) AS bot_messages,
    SUM(CASE WHEN m.sender_type = 'operator' THEN 1 ELSE 0 END) AS operator_messages,
    MIN(m.message_at) AS first_message_at,
    MAX(m.message_at) AS last_message_at
FROM conversations c
LEFT JOIN messages m ON m.conversation_id = c.id
GROUP BY c.id, c.conversation_external_id
ORDER BY total_messages DESC;

-- 4.5 Messages observed without matching incoming/outgoing raw message key
-- Useful to quantify bot/operator messages reconstructed only from /status.
SELECT
    m.message_external_id,
    m.sender_type,
    m.message_at,
    c.conversation_external_id
FROM messages m
JOIN conversations c ON c.id = m.conversation_id
LEFT JOIN webhook_events_raw wr
    ON wr.provider_name = m.provider_name
   AND wr.source_endpoint IN ('incoming', 'outgoing')
   AND wr.external_event_key IN (
       CONCAT('incoming:v1:', m.provider_name, ':message:', m.message_external_id),
       CONCAT('outgoing:v1:', m.provider_name, ':message:', m.message_external_id)
   )
WHERE wr.id IS NULL
ORDER BY m.message_at;

-- =========================================================
-- 5) OPERATOR CONSISTENCY
-- =========================================================

-- 5.1 Real operators with linked volume
SELECT
    o.id,
    o.operator_external_id,
    o.operator_name,
    o.operator_email,
    COUNT(m.id) AS linked_messages
FROM operators o
LEFT JOIN messages m ON m.operator_id = o.id
GROUP BY o.id, o.operator_external_id, o.operator_name, o.operator_email
ORDER BY linked_messages DESC;

-- 5.2 Snapshot last-action-author not present in operators
SELECT
    cs.last_action_author_external_id,
    COUNT(*) AS snapshot_count
FROM conversation_snapshots cs
LEFT JOIN operators o
    ON o.operator_external_id = cs.last_action_author_external_id
WHERE cs.last_action_author_external_id IS NOT NULL
  AND o.id IS NULL
GROUP BY cs.last_action_author_external_id
ORDER BY snapshot_count DESC;

-- =========================================================
-- 6) CONTEXT / TOPIC / PRODUCT / INTENTS
-- =========================================================

-- 6.1 Current coverage of topic/subtopic/product in conversations
SELECT
    COUNT(*) AS conversations_total,
    SUM(CASE WHEN topic IS NOT NULL AND topic <> '' THEN 1 ELSE 0 END) AS with_topic,
    SUM(CASE WHEN subtopic IS NOT NULL AND subtopic <> '' THEN 1 ELSE 0 END) AS with_subtopic,
    SUM(CASE WHEN product IS NOT NULL AND product <> '' THEN 1 ELSE 0 END) AS with_product
FROM conversations;

-- 6.2 Latest context per conversation
WITH latest_context AS (
    SELECT
        cc.*,
        ROW_NUMBER() OVER (
            PARTITION BY cc.conversation_id
            ORDER BY cc.snapshot_at DESC, cc.id DESC
        ) AS rn
    FROM conversation_contexts cc
)
SELECT
    c.conversation_external_id,
    lc.snapshot_at,
    lc.topic,
    lc.subtopic,
    lc.product,
    lc.activity_name,
    lc.completion_message_text
FROM latest_context lc
JOIN conversations c ON c.id = lc.conversation_id
WHERE lc.rn = 1
ORDER BY lc.snapshot_at DESC;

-- 6.3 Intent ranking
SELECT
    jt.intent_name,
    COUNT(*) AS occurrences
FROM conversation_snapshots cs
JOIN JSON_TABLE(
    COALESCE(cs.executed_intents_json, JSON_ARRAY()),
    '$[*]' COLUMNS (
        intent_name VARCHAR(150) PATH '$'
    )
) jt ON TRUE
GROUP BY jt.intent_name
ORDER BY occurrences DESC;

-- 6.4 Dynamic context key coverage
SELECT
    COUNT(*) AS total_contexts,
    SUM(CASE WHEN JSON_EXTRACT(context_json, '$.AP_Actividad') IS NOT NULL THEN 1 ELSE 0 END) AS with_ap_actividad,
    SUM(CASE WHEN JSON_EXTRACT(context_json, '$.BusquedaActividad') IS NOT NULL THEN 1 ELSE 0 END) AS with_busqueda_actividad,
    SUM(CASE WHEN JSON_EXTRACT(context_json, '$.RespuestaAccionCompleta') IS NOT NULL THEN 1 ELSE 0 END) AS with_completion_message
FROM conversation_contexts;

-- 6.5 Activity/product modeling review
-- If product is populated but only from AP_Actividad, product is being overloaded.
SELECT
    cc.product,
    cc.activity_name,
    JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.AP_Actividad')) AS ap_actividad,
    JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.BusquedaActividad')) AS busqueda_actividad,
    COUNT(*) AS context_count
FROM conversation_contexts cc
GROUP BY
    cc.product,
    cc.activity_name,
    JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.AP_Actividad')),
    JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.BusquedaActividad'))
ORDER BY context_count DESC;

-- =========================================================
-- 7) EXACT VS APPROXIMATE METRIC COVERAGE
-- =========================================================

-- 7.1 Coverage of first-response timestamps
SELECT
    COUNT(*) AS total_conversations,
    SUM(CASE WHEN first_human_response_at IS NOT NULL THEN 1 ELSE 0 END) AS with_first_human_response,
    SUM(CASE WHEN first_bot_response_at IS NOT NULL THEN 1 ELSE 0 END) AS with_first_bot_response,
    SUM(CASE WHEN first_user_message_at IS NOT NULL THEN 1 ELSE 0 END) AS with_first_user_message
FROM conversations;

-- 7.2 Coverage of resolution/closure data
SELECT
    COUNT(*) AS total_conversations,
    SUM(CASE WHEN resolved_flag IS NOT NULL THEN 1 ELSE 0 END) AS with_resolved_flag,
    SUM(CASE WHEN closed_at IS NOT NULL THEN 1 ELSE 0 END) AS with_closed_at,
    SUM(CASE WHEN closed_by IS NOT NULL AND closed_by <> '' THEN 1 ELSE 0 END) AS with_closed_by,
    SUM(CASE WHEN handoff_reason IS NOT NULL AND handoff_reason <> '' THEN 1 ELSE 0 END) AS with_handoff_reason
FROM conversations;

-- =========================================================
-- 8) CONVERSATION SUMMARY
-- Use this result to review conversation by conversation before Grafana.
-- =========================================================

SELECT
    c.id,
    c.conversation_external_id,
    cu.customer_external_id,
    c.channel,
    c.status_current,
    c.current_queue_name,
    c.first_user_message_at,
    c.first_bot_response_at,
    c.first_human_response_at,
    c.last_message_at,
    c.last_message_sender_type,
    c.is_bot_muted,
    c.pending_message_count,
    c.topic,
    c.subtopic,
    c.product,
    c.resolved_flag,
    c.closed_at,
    COUNT(DISTINCT m.id) AS total_messages,
    SUM(CASE WHEN m.sender_type = 'customer' THEN 1 ELSE 0 END) AS customer_messages,
    SUM(CASE WHEN m.sender_type = 'bot' THEN 1 ELSE 0 END) AS bot_messages,
    SUM(CASE WHEN m.sender_type = 'operator' THEN 1 ELSE 0 END) AS operator_messages,
    COUNT(DISTINCT cs.id) AS total_snapshots,
    COUNT(DISTINCT cc.id) AS total_contexts
FROM conversations c
JOIN customers cu ON cu.id = c.customer_id
LEFT JOIN messages m ON m.conversation_id = c.id
LEFT JOIN conversation_snapshots cs ON cs.conversation_id = c.id
LEFT JOIN conversation_contexts cc ON cc.conversation_id = c.id
GROUP BY
    c.id,
    c.conversation_external_id,
    cu.customer_external_id,
    c.channel,
    c.status_current,
    c.current_queue_name,
    c.first_user_message_at,
    c.first_bot_response_at,
    c.first_human_response_at,
    c.last_message_at,
    c.last_message_sender_type,
    c.is_bot_muted,
    c.pending_message_count,
    c.topic,
    c.subtopic,
    c.product,
    c.resolved_flag,
    c.closed_at
ORDER BY c.last_message_at DESC;
