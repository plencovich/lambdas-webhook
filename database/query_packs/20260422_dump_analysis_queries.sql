-- Dump audit queries based on the real signal observed in database/dump.sql
-- Scope validated against current data:
--   - tables with rows: webhook_events_raw, customers, operators, conversations,
--     messages, conversation_snapshots, conversation_contexts
--   - topic/subtopic have no current signal
--   - product has weak and contaminated signal
--   - activity_name is the strongest current classification fallback
--   - status_current is delivery status, not conversation business state
-- Structured variants now live under:
--   - database/query_packs/grafana/
--   - database/query_packs/mysql/
-- Reconciliation helpers now live under:
--   - database/reconciliation/

-- =========================================================
-- Q1. Conversations by day
-- Limitation:
--   conversation_started_at can be older than the ingestion day carried by raw events.
-- =========================================================
SELECT
    DATE(conversation_started_at) AS conversation_day,
    COUNT(*) AS conversations
FROM conversations
WHERE conversation_started_at IS NOT NULL
GROUP BY DATE(conversation_started_at)
ORDER BY conversation_day;

-- =========================================================
-- Q2. Messages by day, direction, and sender
-- Good for volume panels and channel/operator/bot mix.
-- =========================================================
SELECT
    DATE(message_at) AS message_day,
    direction,
    sender_type,
    COUNT(*) AS messages
FROM messages
GROUP BY DATE(message_at), direction, sender_type
ORDER BY message_day, direction, sender_type;

-- =========================================================
-- Q3. Observed interaction mode per conversation
-- This is reliable with the current message history.
-- =========================================================
WITH message_rollup AS (
    SELECT
        conversation_id,
        SUM(sender_type = 'customer') AS customer_messages,
        SUM(sender_type = 'bot') AS bot_messages,
        SUM(sender_type = 'operator') AS operator_messages
    FROM messages
    GROUP BY conversation_id
)
SELECT
    CASE
        WHEN operator_messages > 0 AND bot_messages > 0 THEN 'mixed'
        WHEN operator_messages > 0 THEN 'human_only'
        WHEN bot_messages > 0 THEN 'bot_only'
        WHEN customer_messages > 0 THEN 'customer_only'
        ELSE 'unknown'
    END AS interaction_mode_observed,
    COUNT(*) AS conversations
FROM message_rollup
GROUP BY interaction_mode_observed
ORDER BY conversations DESC;

-- =========================================================
-- Q4. Time to first bot/human response
-- Filters negative/out-of-order timelines found in the dump.
-- =========================================================
SELECT
    id AS conversation_id,
    conversation_external_id,
    channel,
    current_queue_name,
    TIMESTAMPDIFF(SECOND, first_user_message_at, first_bot_response_at) AS time_to_first_bot_response_seconds,
    TIMESTAMPDIFF(SECOND, first_user_message_at, first_human_response_at) AS time_to_first_human_response_seconds
FROM conversations
WHERE first_user_message_at IS NOT NULL
  AND (
      first_bot_response_at IS NULL
      OR first_bot_response_at >= first_user_message_at
  )
  AND (
      first_human_response_at IS NULL
      OR first_human_response_at >= first_user_message_at
  )
ORDER BY conversation_id;

-- Aggregate view of the same SLA metrics.
SELECT
    COUNT(*) AS conversations_with_user_message,
    AVG(
        CASE
            WHEN first_bot_response_at IS NOT NULL
             AND first_bot_response_at >= first_user_message_at
            THEN TIMESTAMPDIFF(SECOND, first_user_message_at, first_bot_response_at)
        END
    ) AS avg_time_to_first_bot_response_seconds,
    AVG(
        CASE
            WHEN first_human_response_at IS NOT NULL
             AND first_human_response_at >= first_user_message_at
            THEN TIMESTAMPDIFF(SECOND, first_user_message_at, first_human_response_at)
        END
    ) AS avg_time_to_first_human_response_seconds
FROM conversations
WHERE first_user_message_at IS NOT NULL;

-- =========================================================
-- Q5. Conversation activity duration
-- Limitation:
--   this is duration between first known start and last known message, not exact resolution time.
-- =========================================================
SELECT
    id AS conversation_id,
    conversation_external_id,
    current_queue_name,
    TIMESTAMPDIFF(SECOND, conversation_started_at, last_message_at) AS activity_seconds
FROM conversations
WHERE conversation_started_at IS NOT NULL
  AND last_message_at IS NOT NULL
  AND last_message_at >= conversation_started_at
ORDER BY activity_seconds DESC;

-- =========================================================
-- Q6. Queue usage
-- Use conversation current queue for current state and messages for traffic.
-- =========================================================
SELECT
    COALESCE(current_queue_name, 'unknown') AS current_queue_name,
    COUNT(*) AS conversations
FROM conversations
GROUP BY COALESCE(current_queue_name, 'unknown')
ORDER BY conversations DESC;

SELECT
    COALESCE(queue_name, 'unknown') AS queue_name,
    sender_type,
    COUNT(*) AS messages
FROM messages
GROUP BY COALESCE(queue_name, 'unknown'), sender_type
ORDER BY messages DESC, queue_name, sender_type;

-- =========================================================
-- Q7. Operators with more interactions
-- =========================================================
SELECT
    COALESCE(o.operator_name, m.sender_name, 'unknown') AS operator_name,
    o.operator_email,
    COUNT(*) AS operator_messages,
    COUNT(DISTINCT m.conversation_id) AS conversations_touched
FROM messages m
LEFT JOIN operators o
    ON o.id = m.operator_id
WHERE m.sender_type = 'operator'
GROUP BY COALESCE(o.operator_name, m.sender_name, 'unknown'), o.operator_email
ORDER BY operator_messages DESC, conversations_touched DESC;

-- =========================================================
-- Q8. Buttons and attachments
-- Limitation:
--   attachment detail is partially degraded by later status updates in current persisted data.
-- =========================================================
SELECT
    DATE(message_at) AS message_day,
    COUNT(*) AS button_messages,
    COUNT(DISTINCT conversation_id) AS conversations_with_buttons
FROM messages
WHERE is_button = 1
GROUP BY DATE(message_at)
ORDER BY message_day;

SELECT
    COALESCE(attachment_type, 'unknown') AS attachment_type,
    COUNT(*) AS messages
FROM messages
WHERE has_attachment = 1
GROUP BY COALESCE(attachment_type, 'unknown')
ORDER BY messages DESC, attachment_type;

-- =========================================================
-- Q9. Handoff to human approximation
-- Current signal is good enough for an approximate rate.
-- =========================================================
WITH message_rollup AS (
    SELECT
        conversation_id,
        SUM(sender_type = 'operator') AS operator_messages
    FROM messages
    GROUP BY conversation_id
)
SELECT
    COUNT(*) AS conversations,
    SUM(
        CASE
            WHEN c.first_human_response_at IS NOT NULL OR COALESCE(mr.operator_messages, 0) > 0
            THEN 1 ELSE 0
        END
    ) AS handoff_to_human_aprox,
    ROUND(
        100 * SUM(
            CASE
                WHEN c.first_human_response_at IS NOT NULL OR COALESCE(mr.operator_messages, 0) > 0
                THEN 1 ELSE 0
            END
        ) / COUNT(*),
        2
    ) AS handoff_to_human_aprox_pct
FROM conversations c
LEFT JOIN message_rollup mr
    ON mr.conversation_id = c.id;

-- =========================================================
-- Q10. Classification coverage with real current signal
-- Use latest context. topic/subtopic are expected to be empty today.
-- =========================================================
WITH latest_context AS (
    SELECT *
    FROM (
        SELECT
            cc.*,
            ROW_NUMBER() OVER (
                PARTITION BY cc.conversation_id
                ORDER BY cc.snapshot_at DESC, cc.id DESC
            ) AS rn
        FROM conversation_contexts cc
    ) ranked
    WHERE rn = 1
)
SELECT
    COUNT(*) AS conversations,
    SUM(c.topic IS NOT NULL) AS with_topic,
    SUM(c.subtopic IS NOT NULL) AS with_subtopic,
    SUM(c.product IS NOT NULL) AS with_conversation_product,
    SUM(lc.activity_name IS NOT NULL) AS with_latest_activity_name,
    SUM(lc.quote_external_id IS NOT NULL OR lc.coverage_external_id IS NOT NULL) AS with_latest_quote_signal,
    SUM(lc.completion_message_text IS NOT NULL) AS with_latest_completion_message
FROM conversations c
LEFT JOIN latest_context lc
    ON lc.conversation_id = c.id;

-- Breakdown of latest activity_name.
WITH latest_context AS (
    SELECT *
    FROM (
        SELECT
            cc.*,
            ROW_NUMBER() OVER (
                PARTITION BY cc.conversation_id
                ORDER BY cc.snapshot_at DESC, cc.id DESC
            ) AS rn
        FROM conversation_contexts cc
    ) ranked
    WHERE rn = 1
)
SELECT
    activity_name,
    COUNT(*) AS conversations
FROM latest_context
WHERE activity_name IS NOT NULL
GROUP BY activity_name
ORDER BY conversations DESC, activity_name;

-- =========================================================
-- Q11. Quotes / coverage generation
-- Good today because quote fields have real signal in the dump.
-- =========================================================
WITH latest_context AS (
    SELECT *
    FROM (
        SELECT
            cc.*,
            ROW_NUMBER() OVER (
                PARTITION BY cc.conversation_id
                ORDER BY cc.snapshot_at DESC, cc.id DESC
            ) AS rn
        FROM conversation_contexts cc
    ) ranked
    WHERE rn = 1
)
SELECT
    COUNT(*) AS conversations,
    SUM(quote_external_id IS NOT NULL) AS with_quote_id,
    SUM(coverage_external_id IS NOT NULL) AS with_coverage_id,
    SUM(quoted_total_amount IS NOT NULL) AS with_amount,
    SUM(quote_description IS NOT NULL) AS with_quote_description
FROM latest_context;

-- =========================================================
-- Q12. Current conversation state
-- Limitation:
--   current state is the last delivery state, not an exact business resolution state.
-- =========================================================
SELECT
    status_current,
    last_message_sender_type,
    COUNT(*) AS conversations
FROM conversations
GROUP BY status_current, last_message_sender_type
ORDER BY conversations DESC, status_current, last_message_sender_type;

-- =========================================================
-- Q13. Redundant context rows
-- Shows exact repeated context snapshots; this is the main redundancy issue today.
-- =========================================================
SELECT
    conversation_id,
    snapshot_at,
    product,
    activity_name,
    quote_external_id,
    coverage_external_id,
    completion_message_text,
    context_json,
    COUNT(*) AS repeated_rows
FROM conversation_contexts
GROUP BY
    conversation_id,
    snapshot_at,
    product,
    activity_name,
    quote_external_id,
    coverage_external_id,
    completion_message_text,
    context_json
HAVING COUNT(*) > 1
ORDER BY repeated_rows DESC, conversation_id, snapshot_at;

-- Consecutive unchanged context rows by conversation.
WITH ordered_contexts AS (
    SELECT
        cc.*,
        LAG(product) OVER (PARTITION BY conversation_id ORDER BY snapshot_at, id) AS prev_product,
        LAG(topic) OVER (PARTITION BY conversation_id ORDER BY snapshot_at, id) AS prev_topic,
        LAG(subtopic) OVER (PARTITION BY conversation_id ORDER BY snapshot_at, id) AS prev_subtopic,
        LAG(quote_external_id) OVER (PARTITION BY conversation_id ORDER BY snapshot_at, id) AS prev_quote_external_id,
        LAG(coverage_external_id) OVER (PARTITION BY conversation_id ORDER BY snapshot_at, id) AS prev_coverage_external_id,
        LAG(quoted_total_amount) OVER (PARTITION BY conversation_id ORDER BY snapshot_at, id) AS prev_quoted_total_amount,
        LAG(quote_description) OVER (PARTITION BY conversation_id ORDER BY snapshot_at, id) AS prev_quote_description,
        LAG(activity_name) OVER (PARTITION BY conversation_id ORDER BY snapshot_at, id) AS prev_activity_name,
        LAG(completion_message_text) OVER (PARTITION BY conversation_id ORDER BY snapshot_at, id) AS prev_completion_message_text,
        LAG(context_json) OVER (PARTITION BY conversation_id ORDER BY snapshot_at, id) AS prev_context_json
    FROM conversation_contexts cc
)
SELECT
    conversation_id,
    COUNT(*) AS unchanged_consecutive_rows
FROM ordered_contexts
WHERE COALESCE(product, '__null__') = COALESCE(prev_product, '__null__')
  AND COALESCE(topic, '__null__') = COALESCE(prev_topic, '__null__')
  AND COALESCE(subtopic, '__null__') = COALESCE(prev_subtopic, '__null__')
  AND COALESCE(quote_external_id, '__null__') = COALESCE(prev_quote_external_id, '__null__')
  AND COALESCE(coverage_external_id, '__null__') = COALESCE(prev_coverage_external_id, '__null__')
  AND COALESCE(CAST(quoted_total_amount AS CHAR), '__null__') = COALESCE(CAST(prev_quoted_total_amount AS CHAR), '__null__')
  AND COALESCE(quote_description, '__null__') = COALESCE(prev_quote_description, '__null__')
  AND COALESCE(activity_name, '__null__') = COALESCE(prev_activity_name, '__null__')
  AND COALESCE(completion_message_text, '__null__') = COALESCE(prev_completion_message_text, '__null__')
  AND COALESCE(CAST(context_json AS CHAR), '__null__') = COALESCE(CAST(prev_context_json AS CHAR), '__null__')
GROUP BY conversation_id
ORDER BY unchanged_consecutive_rows DESC, conversation_id;

-- =========================================================
-- Q14. Sensitive key audit in raw and derived context
-- Useful to track cleanup after mapper changes.
-- =========================================================
SELECT 'webhook_events_raw' AS source_table, 'AP_User_Password' AS key_name, COUNT(*) AS occurrences
FROM webhook_events_raw
WHERE source_endpoint = 'status'
  AND JSON_EXTRACT(raw_payload_json, '$.AP_User_Password') IS NOT NULL
UNION ALL
SELECT 'webhook_events_raw', 'AP_DNITomador', COUNT(*)
FROM webhook_events_raw
WHERE source_endpoint = 'status'
  AND JSON_EXTRACT(raw_payload_json, '$.AP_DNITomador') IS NOT NULL
UNION ALL
SELECT 'webhook_events_raw', 'Siniestro_DNIAseg', COUNT(*)
FROM webhook_events_raw
WHERE source_endpoint = 'status'
  AND JSON_EXTRACT(raw_payload_json, '$.Siniestro_DNIAseg') IS NOT NULL
UNION ALL
SELECT 'conversation_contexts', 'AP_User_Password', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_User_Password') IS NOT NULL
UNION ALL
SELECT 'conversation_contexts', 'AP_DNITomador', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_DNITomador') IS NOT NULL
UNION ALL
SELECT 'conversation_contexts', 'AP_User_Nombre', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_User_Nombre') IS NOT NULL
UNION ALL
SELECT 'conversation_contexts', 'AP_User_Apellido', COUNT(*)
FROM conversation_contexts
WHERE JSON_EXTRACT(context_json, '$.AP_User_Apellido') IS NOT NULL;

-- =========================================================
-- Q15. Audit of messages whose richer native payload was overwritten by status
-- This query exposes the current repository merge problem.
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
    ) AS outgoing_messages_overwritten_by_status_payload,
    SUM(
        has_incoming_raw = 1
        AND has_status_raw = 1
        AND JSON_EXTRACT(m.client_payload, '$.last_message') IS NOT NULL
    ) AS incoming_messages_overwritten_by_status_payload
FROM raw_message_endpoints rme
JOIN messages m
    ON m.message_external_id = rme.message_external_id;
