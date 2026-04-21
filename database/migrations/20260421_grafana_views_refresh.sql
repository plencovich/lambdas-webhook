-- =========================================================
-- Grafana analytics view refresh
-- Target: MySQL 8.x / AWS RDS
--
-- Purpose:
--   Refresh Grafana views in environments where the base migration
--   was already applied and only the view definitions need to be
--   synchronized.
--
-- When to use:
--   - Unknown column errors in Grafana analytic views
--   - New derived columns were added to vw_grafana_conversations_current
--   - New dependent views were added after the initial migration
--
-- Notes:
--   - This script does not touch indexes.
--   - Run after database/init_db.sql and after the base analytic
--     migration if the indexes already exist.
-- =========================================================

SET NAMES utf8mb4;

-- =========================================================
-- 1) Latest context per conversation
-- =========================================================

CREATE OR REPLACE VIEW vw_grafana_conversation_latest_context AS
SELECT
    ranked.context_id,
    ranked.provider_name,
    ranked.conversation_id,
    ranked.customer_id,
    ranked.snapshot_at,
    ranked.product,
    ranked.topic,
    ranked.subtopic,
    ranked.quote_external_id,
    ranked.coverage_external_id,
    ranked.quoted_total_amount,
    ranked.quote_description,
    ranked.activity_name,
    ranked.completion_message_text,
    ranked.context_json
FROM (
    SELECT
        cc.id AS context_id,
        cc.provider_name,
        cc.conversation_id,
        cc.customer_id,
        cc.snapshot_at,
        cc.product,
        cc.topic,
        cc.subtopic,
        cc.quote_external_id,
        cc.coverage_external_id,
        cc.quoted_total_amount,
        cc.quote_description,
        cc.activity_name,
        cc.completion_message_text,
        cc.context_json,
        ROW_NUMBER() OVER (
            PARTITION BY cc.conversation_id
            ORDER BY cc.snapshot_at DESC, cc.id DESC
        ) AS row_num
    FROM conversation_contexts cc
) ranked
WHERE ranked.row_num = 1;

-- =========================================================
-- 2) Message-derived per-conversation metrics
-- =========================================================

CREATE OR REPLACE VIEW vw_grafana_conversation_message_metrics_from_messages AS
SELECT
    m.conversation_id,
    COUNT(*) AS message_count_observed,
    SUM(CASE WHEN m.sender_type = 'customer' THEN 1 ELSE 0 END) AS message_count_user_observed,
    SUM(CASE WHEN m.sender_type = 'bot' THEN 1 ELSE 0 END) AS message_count_bot_observed,
    SUM(CASE WHEN m.sender_type = 'operator' THEN 1 ELSE 0 END) AS message_count_operator_observed,
    MIN(CASE WHEN m.sender_type = 'customer' THEN m.message_at END) AS first_user_message_at_observed,
    MIN(CASE WHEN m.sender_type = 'bot' THEN m.message_at END) AS first_bot_message_at_observed,
    MIN(CASE WHEN m.sender_type = 'operator' THEN m.message_at END) AS first_operator_message_at_observed,
    MAX(m.message_at) AS last_message_at_observed,
    SUM(CASE WHEN m.has_attachment = 1 THEN 1 ELSE 0 END) AS attachment_message_count_observed,
    CASE
        WHEN SUM(CASE WHEN m.sender_type = 'bot' THEN 1 ELSE 0 END) > 0 THEN 1
        ELSE 0
    END AS had_bot_intervention_observed,
    CASE
        WHEN SUM(CASE WHEN m.sender_type = 'operator' THEN 1 ELSE 0 END) > 0 THEN 1
        ELSE 0
    END AS had_human_intervention_observed,
    CASE
        WHEN SUM(CASE WHEN m.sender_type = 'bot' THEN 1 ELSE 0 END) > 0
         AND SUM(CASE WHEN m.sender_type = 'operator' THEN 1 ELSE 0 END) > 0 THEN 'mixed'
        WHEN SUM(CASE WHEN m.sender_type = 'operator' THEN 1 ELSE 0 END) > 0 THEN 'human_only'
        WHEN SUM(CASE WHEN m.sender_type = 'bot' THEN 1 ELSE 0 END) > 0 THEN 'bot_only'
        WHEN SUM(CASE WHEN m.sender_type = 'customer' THEN 1 ELSE 0 END) > 0 THEN 'customer_only_observed'
        ELSE 'unknown'
    END AS interaction_mode_observed
FROM messages m
GROUP BY m.conversation_id;

-- =========================================================
-- 3) Current conversation view
-- =========================================================

CREATE OR REPLACE VIEW vw_grafana_conversations_current AS
SELECT
    c.id AS conversation_id,
    c.provider_name,
    c.conversation_external_id,
    c.customer_id,
    cu.customer_external_id,
    cu.contact_external_id,
    c.channel,
    c.business_channel_id,
    c.business_channel_address,
    c.current_queue_name,
    c.status_current,
    c.is_bot_muted,
    c.pending_message_count,
    c.conversation_started_at,
    c.first_user_message_at,
    c.first_bot_response_at,
    c.first_human_response_at,
    c.last_message_at,
    c.last_message_sender_type,
    c.last_action_author_external_id,
    c.resolved_flag,
    c.resolution_type,
    c.closed_by,
    c.closed_at,
    COALESCE(c.topic, lc.topic) AS topic,
    COALESCE(c.subtopic, lc.subtopic) AS subtopic,
    COALESCE(c.product, lc.product) AS product,
    COALESCE(
        c.subtopic,
        lc.subtopic,
        c.topic,
        lc.topic,
        lc.activity_name,
        c.product,
        lc.product
    ) AS motivo_consulta_aprox,
    c.journey_stage,
    c.handoff_reason,
    lc.activity_name,
    lc.quote_external_id,
    lc.coverage_external_id,
    mm.message_count_observed,
    mm.message_count_user_observed,
    mm.message_count_bot_observed,
    mm.message_count_operator_observed,
    mm.had_bot_intervention_observed,
    mm.had_human_intervention_observed,
    mm.interaction_mode_observed,
    CASE
        WHEN c.first_user_message_at IS NOT NULL
         AND c.first_bot_response_at IS NOT NULL THEN
            TIMESTAMPDIFF(SECOND, c.first_user_message_at, c.first_bot_response_at)
        ELSE NULL
    END AS time_to_first_bot_response_seconds,
    CASE
        WHEN c.first_user_message_at IS NOT NULL
         AND c.first_human_response_at IS NOT NULL THEN
            TIMESTAMPDIFF(SECOND, c.first_user_message_at, c.first_human_response_at)
        ELSE NULL
    END AS time_to_first_human_response_seconds,
    CASE
        WHEN c.first_user_message_at IS NULL
         AND c.conversation_started_at IS NOT NULL
         AND c.first_bot_response_at IS NOT NULL THEN
            TIMESTAMPDIFF(SECOND, c.conversation_started_at, c.first_bot_response_at)
        ELSE NULL
    END AS time_to_first_bot_response_seconds_aprox,
    CASE
        WHEN c.first_user_message_at IS NULL
         AND c.conversation_started_at IS NOT NULL
         AND c.first_human_response_at IS NOT NULL THEN
            TIMESTAMPDIFF(SECOND, c.conversation_started_at, c.first_human_response_at)
        ELSE NULL
    END AS time_to_first_human_response_seconds_aprox,
    CASE
        WHEN c.conversation_started_at IS NOT NULL
         AND c.closed_at IS NOT NULL THEN
            TIMESTAMPDIFF(SECOND, c.conversation_started_at, c.closed_at)
        ELSE NULL
    END AS resolution_time_seconds,
    CASE
        WHEN c.first_human_response_at IS NOT NULL
          OR COALESCE(mm.message_count_operator_observed, 0) > 0 THEN 1
        ELSE 0
    END AS handoff_to_human_aprox,
    CASE
        WHEN c.closed_at IS NOT NULL THEN 'exact_closed_at'
        WHEN c.resolved_flag IS NOT NULL THEN 'resolved_flag_without_closed_at'
        ELSE 'not_available'
    END AS resolution_data_quality,
    CASE
        WHEN COALESCE(mm.message_count_user_observed, 0) > 0
         AND (
            COALESCE(mm.message_count_bot_observed, 0) > 0
            OR COALESCE(mm.message_count_operator_observed, 0) > 0
         ) THEN 'message_history_observed'
        ELSE 'status_or_partial_history'
    END AS message_history_quality
FROM conversations c
JOIN customers cu
  ON cu.id = c.customer_id
LEFT JOIN vw_grafana_conversation_latest_context lc
  ON lc.conversation_id = c.id
LEFT JOIN vw_grafana_conversation_message_metrics_from_messages mm
  ON mm.conversation_id = c.id;

-- =========================================================
-- 4) Aggregates and dependent views
-- =========================================================

CREATE OR REPLACE VIEW vw_grafana_conversations_daily AS
SELECT
    DATE(COALESCE(conversation_started_at, last_message_at)) AS conversation_date,
    provider_name,
    channel,
    COALESCE(status_current, 'unknown') AS status_current,
    COALESCE(current_queue_name, 'unknown') AS queue_name,
    COALESCE(topic, 'unknown') AS topic,
    COALESCE(subtopic, 'unknown') AS subtopic,
    COALESCE(product, 'unknown') AS product,
    COUNT(*) AS conversation_count,
    SUM(CASE WHEN is_bot_muted = 1 THEN 1 ELSE 0 END) AS bot_muted_count,
    SUM(CASE WHEN pending_message_count > 0 THEN 1 ELSE 0 END) AS conversations_with_pending_messages,
    SUM(CASE WHEN handoff_to_human_aprox = 1 THEN 1 ELSE 0 END) AS handoff_to_human_count_aprox,
    SUM(CASE WHEN resolved_flag = 1 THEN 1 ELSE 0 END) AS resolved_count,
    AVG(time_to_first_bot_response_seconds) AS avg_time_to_first_bot_response_seconds,
    AVG(time_to_first_human_response_seconds) AS avg_time_to_first_human_response_seconds,
    AVG(time_to_first_bot_response_seconds_aprox) AS avg_time_to_first_bot_response_seconds_aprox,
    AVG(time_to_first_human_response_seconds_aprox) AS avg_time_to_first_human_response_seconds_aprox,
    AVG(resolution_time_seconds) AS avg_resolution_time_seconds
FROM vw_grafana_conversations_current
GROUP BY
    DATE(COALESCE(conversation_started_at, last_message_at)),
    provider_name,
    channel,
    COALESCE(status_current, 'unknown'),
    COALESCE(current_queue_name, 'unknown'),
    COALESCE(topic, 'unknown'),
    COALESCE(subtopic, 'unknown'),
    COALESCE(product, 'unknown');

CREATE OR REPLACE VIEW vw_grafana_queue_channel_status_current AS
SELECT
    provider_name,
    channel,
    COALESCE(current_queue_name, 'unknown') AS queue_name,
    COALESCE(status_current, 'unknown') AS status_current,
    COUNT(*) AS conversation_count,
    SUM(CASE WHEN is_bot_muted = 1 THEN 1 ELSE 0 END) AS bot_muted_count,
    SUM(CASE WHEN pending_message_count > 0 THEN 1 ELSE 0 END) AS conversations_with_pending_messages,
    SUM(CASE WHEN handoff_to_human_aprox = 1 THEN 1 ELSE 0 END) AS handoff_to_human_count_aprox
FROM vw_grafana_conversations_current
GROUP BY
    provider_name,
    channel,
    COALESCE(current_queue_name, 'unknown'),
    COALESCE(status_current, 'unknown');

CREATE OR REPLACE VIEW vw_grafana_conversation_snapshots AS
SELECT
    cs.id AS snapshot_id,
    cs.provider_name,
    cs.conversation_id,
    c.conversation_external_id,
    cs.customer_id,
    cu.customer_external_id,
    c.channel,
    cs.snapshot_at,
    cs.status_current,
    cs.is_bot_muted,
    cs.pending_message_count,
    cs.last_seen_at,
    cs.last_user_message_received_at,
    cs.last_user_message_read_at,
    cs.last_action_author_external_id,
    cs.queue_name,
    cs.executed_intents_json,
    cs.last_message_external_id,
    cs.last_message_at,
    cs.last_message_sender_type,
    cs.last_message_sender_name,
    cs.last_message_text,
    cs.operator_external_id,
    cs.operator_name,
    cs.operator_email
FROM conversation_snapshots cs
JOIN conversations c
  ON c.id = cs.conversation_id
JOIN customers cu
  ON cu.id = cs.customer_id;

CREATE OR REPLACE VIEW vw_grafana_snapshots_daily AS
SELECT
    DATE(snapshot_at) AS snapshot_date,
    provider_name,
    channel,
    COALESCE(status_current, 'unknown') AS status_current,
    COALESCE(queue_name, 'unknown') AS queue_name,
    COUNT(*) AS snapshot_count,
    COUNT(DISTINCT conversation_id) AS conversation_count,
    SUM(CASE WHEN is_bot_muted = 1 THEN 1 ELSE 0 END) AS bot_muted_snapshot_count,
    SUM(CASE WHEN pending_message_count > 0 THEN 1 ELSE 0 END) AS pending_message_snapshot_count,
    AVG(pending_message_count) AS avg_pending_message_count
FROM vw_grafana_conversation_snapshots
GROUP BY
    DATE(snapshot_at),
    provider_name,
    channel,
    COALESCE(status_current, 'unknown'),
    COALESCE(queue_name, 'unknown');

CREATE OR REPLACE VIEW vw_grafana_executed_intents AS
SELECT
    cs.id AS snapshot_id,
    cs.provider_name,
    cs.conversation_id,
    c.conversation_external_id,
    cs.customer_id,
    cu.customer_external_id,
    c.channel,
    cs.queue_name,
    cs.snapshot_at,
    intent_items.intent_name
FROM conversation_snapshots cs
JOIN conversations c
  ON c.id = cs.conversation_id
JOIN customers cu
  ON cu.id = cs.customer_id
JOIN JSON_TABLE(
    COALESCE(cs.executed_intents_json, JSON_ARRAY()),
    '$[*]' COLUMNS (
        intent_name VARCHAR(150) PATH '$'
    )
) AS intent_items
  ON TRUE
WHERE intent_items.intent_name IS NOT NULL
  AND intent_items.intent_name <> '';

CREATE OR REPLACE VIEW vw_grafana_intents_daily AS
SELECT
    DATE(snapshot_at) AS intent_date,
    provider_name,
    channel,
    COALESCE(queue_name, 'unknown') AS queue_name,
    intent_name,
    COUNT(*) AS intent_occurrence_count,
    COUNT(DISTINCT conversation_id) AS conversation_count
FROM vw_grafana_executed_intents
GROUP BY
    DATE(snapshot_at),
    provider_name,
    channel,
    COALESCE(queue_name, 'unknown'),
    intent_name;

CREATE OR REPLACE VIEW vw_grafana_messages_from_messages AS
SELECT
    m.id AS message_id,
    m.provider_name,
    m.message_external_id,
    m.conversation_id,
    c.conversation_external_id,
    m.customer_id,
    cu.customer_external_id,
    m.operator_id,
    op.operator_external_id,
    op.operator_name,
    op.operator_email,
    c.channel,
    m.queue_name,
    m.message_at,
    m.direction,
    m.sender_type,
    m.sender_name,
    m.is_button,
    m.is_customer_message,
    m.has_attachment,
    m.attachment_type,
    m.intent_name,
    m.delivery_status,
    m.delivery_status_at
FROM messages m
JOIN conversations c
  ON c.id = m.conversation_id
JOIN customers cu
  ON cu.id = m.customer_id
LEFT JOIN operators op
  ON op.id = m.operator_id;

CREATE OR REPLACE VIEW vw_grafana_messages_daily_from_messages AS
SELECT
    DATE(message_at) AS message_date,
    provider_name,
    channel,
    COALESCE(queue_name, 'unknown') AS queue_name,
    direction,
    sender_type,
    COALESCE(delivery_status, 'unknown') AS delivery_status,
    COUNT(*) AS message_count,
    COUNT(DISTINCT conversation_id) AS conversation_count,
    SUM(CASE WHEN has_attachment = 1 THEN 1 ELSE 0 END) AS attachment_message_count
FROM vw_grafana_messages_from_messages
GROUP BY
    DATE(message_at),
    provider_name,
    channel,
    COALESCE(queue_name, 'unknown'),
    direction,
    sender_type,
    COALESCE(delivery_status, 'unknown');

CREATE OR REPLACE VIEW vw_grafana_operator_volume_from_messages AS
SELECT
    DATE(message_at) AS message_date,
    provider_name,
    channel,
    COALESCE(queue_name, 'unknown') AS queue_name,
    operator_id,
    operator_external_id,
    COALESCE(operator_name, sender_name, 'unknown') AS operator_name,
    operator_email,
    COUNT(*) AS outbound_message_count,
    COUNT(DISTINCT conversation_id) AS conversation_count
FROM vw_grafana_messages_from_messages
WHERE sender_type = 'operator'
GROUP BY
    DATE(message_at),
    provider_name,
    channel,
    COALESCE(queue_name, 'unknown'),
    operator_id,
    operator_external_id,
    COALESCE(operator_name, sender_name, 'unknown'),
    operator_email;

CREATE OR REPLACE VIEW vw_grafana_resolution_current AS
SELECT
    conversation_id,
    provider_name,
    conversation_external_id,
    customer_external_id,
    channel,
    current_queue_name,
    status_current,
    topic,
    subtopic,
    product,
    conversation_started_at,
    first_user_message_at,
    first_bot_response_at,
    first_human_response_at,
    closed_at,
    resolved_flag,
    resolution_type,
    closed_by,
    resolution_time_seconds,
    resolution_data_quality,
    time_to_first_bot_response_seconds,
    time_to_first_human_response_seconds,
    time_to_first_bot_response_seconds_aprox,
    time_to_first_human_response_seconds_aprox,
    handoff_to_human_aprox,
    handoff_reason
FROM vw_grafana_conversations_current;

CREATE OR REPLACE VIEW vw_grafana_handoff_to_human_aprox AS
SELECT
    conversation_id,
    provider_name,
    conversation_external_id,
    customer_external_id,
    channel,
    current_queue_name,
    status_current,
    topic,
    subtopic,
    product,
    conversation_started_at,
    first_human_response_at,
    message_count_operator_observed,
    handoff_to_human_aprox,
    CASE
        WHEN first_human_response_at IS NOT NULL THEN 'first_human_response_at'
        WHEN COALESCE(message_count_operator_observed, 0) > 0 THEN 'operator_message_observed'
        ELSE 'not_handoff_observed'
    END AS handoff_detection_basis_aprox
FROM vw_grafana_conversations_current
WHERE handoff_to_human_aprox = 1;

CREATE OR REPLACE VIEW vw_grafana_activity_motive_breakdown_current AS
SELECT
    provider_name,
    channel,
    COALESCE(activity_name, 'unknown') AS activity_name,
    COALESCE(motivo_consulta_aprox, 'unknown') AS motivo_consulta_aprox,
    COALESCE(topic, 'unknown') AS topic,
    COALESCE(subtopic, 'unknown') AS subtopic,
    COALESCE(product, 'unknown') AS product,
    COUNT(*) AS conversation_count,
    SUM(CASE WHEN handoff_to_human_aprox = 1 THEN 1 ELSE 0 END) AS handoff_to_human_count_aprox,
    SUM(CASE WHEN resolved_flag = 1 THEN 1 ELSE 0 END) AS resolved_count,
    AVG(time_to_first_human_response_seconds) AS avg_time_to_first_human_response_seconds,
    AVG(time_to_first_human_response_seconds_aprox) AS avg_time_to_first_human_response_seconds_aprox
FROM vw_grafana_conversations_current
GROUP BY
    provider_name,
    channel,
    COALESCE(activity_name, 'unknown'),
    COALESCE(motivo_consulta_aprox, 'unknown'),
    COALESCE(topic, 'unknown'),
    COALESCE(subtopic, 'unknown'),
    COALESCE(product, 'unknown');
