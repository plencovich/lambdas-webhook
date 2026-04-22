-- =========================================================
-- Grafana analytics reconciliation
-- Target: MySQL 8.x / AWS RDS
--
-- Purpose:
--   Reconcile the Grafana analytics layer against the observed
--   webhook data exported on 2026-04-21.
--
-- Scope:
--   - keep the operational schema untouched
--   - avoid new tables
--   - normalize blank strings in analytics views
--   - separate exact vs approximate signals explicitly
--   - stop using product as a silent fallback for motive/topic
--
-- Safety:
--   - safe to rerun in populated environments
--   - only adds one dashboard-oriented index if it is missing
--   - refreshes views with DROP VIEW IF EXISTS + CREATE VIEW
-- =========================================================

SET NAMES utf8mb4;

-- =========================================================
-- 1) Minimal index reconciliation
--
-- Existing dashboard indexes from 20260420 are largely sufficient.
-- This migration adds only the missing activity-oriented index used
-- by the new breakdown view.
-- =========================================================

SET @idx_exists := (
    SELECT COUNT(*)
    FROM information_schema.statistics
    WHERE table_schema = DATABASE()
      AND table_name = 'conversation_contexts'
      AND index_name = 'idx_conversation_contexts_activity_snapshot'
);

SET @idx_sql := IF(
    @idx_exists = 0,
    'ALTER TABLE conversation_contexts ADD INDEX idx_conversation_contexts_activity_snapshot (activity_name, snapshot_at)',
    'SELECT ''idx_conversation_contexts_activity_snapshot already exists'''
);

PREPARE stmt FROM @idx_sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- =========================================================
-- 2) Drop dependent views first
-- =========================================================

DROP VIEW IF EXISTS vw_grafana_activity_motive_breakdown_current;
DROP VIEW IF EXISTS vw_grafana_handoff_to_human_aprox;
DROP VIEW IF EXISTS vw_grafana_resolution_current;
DROP VIEW IF EXISTS vw_grafana_queue_channel_status_current;
DROP VIEW IF EXISTS vw_grafana_conversations_daily;
DROP VIEW IF EXISTS vw_grafana_conversations_current;
DROP VIEW IF EXISTS vw_grafana_conversation_message_metrics_from_messages;
DROP VIEW IF EXISTS vw_grafana_conversation_latest_context;

-- =========================================================
-- 3) Latest context per conversation
--
-- Notes:
--   - blank strings are normalized to NULL for analytics
--   - activity_name prefers ActividadName over AP_Actividad
--   - IssueResuelto and BusquedaActividad are exposed explicitly
-- =========================================================

CREATE VIEW vw_grafana_conversation_latest_context AS
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
    ranked.activity_name_source,
    ranked.activity_code,
    ranked.ap_actividad,
    ranked.busqueda_actividad_flag,
    ranked.issue_resuelto_flag,
    ranked.completion_message_text,
    ranked.context_json
FROM (
    SELECT
        cc.id AS context_id,
        cc.provider_name,
        cc.conversation_id,
        cc.customer_id,
        cc.snapshot_at,
        NULLIF(TRIM(cc.product), '') AS product,
        NULLIF(TRIM(cc.topic), '') AS topic,
        NULLIF(TRIM(cc.subtopic), '') AS subtopic,
        NULLIF(TRIM(cc.quote_external_id), '') AS quote_external_id,
        NULLIF(TRIM(cc.coverage_external_id), '') AS coverage_external_id,
        CASE
            WHEN cc.quoted_total_amount IS NULL THEN NULL
            WHEN cc.quoted_total_amount = 0
             AND NULLIF(TRIM(cc.quote_external_id), '') IS NULL
             AND NULLIF(TRIM(cc.coverage_external_id), '') IS NULL THEN NULL
            ELSE cc.quoted_total_amount
        END AS quoted_total_amount,
        NULLIF(TRIM(cc.quote_description), '') AS quote_description,
        COALESCE(
            NULLIF(TRIM(JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.ActividadName'))), ''),
            NULLIF(TRIM(cc.activity_name), ''),
            NULLIF(TRIM(JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.AP_Actividad'))), '')
        ) AS activity_name,
        CASE
            WHEN NULLIF(TRIM(JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.ActividadName'))), '') IS NOT NULL THEN 'ActividadName'
            WHEN NULLIF(TRIM(cc.activity_name), '') IS NOT NULL THEN 'activity_name_column'
            WHEN NULLIF(TRIM(JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.AP_Actividad'))), '') IS NOT NULL THEN 'AP_Actividad'
            ELSE 'not_available'
        END AS activity_name_source,
        NULLIF(TRIM(JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.ActividadCode'))), '') AS activity_code,
        NULLIF(TRIM(JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.AP_Actividad'))), '') AS ap_actividad,
        CASE
            WHEN LOWER(NULLIF(TRIM(JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.BusquedaActividad'))), '')) IN ('1', 'true', 'yes', 'si', 'sí', 'y') THEN 1
            WHEN LOWER(NULLIF(TRIM(JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.BusquedaActividad'))), '')) IN ('0', 'false', 'no', 'n') THEN 0
            ELSE NULL
        END AS busqueda_actividad_flag,
        CASE
            WHEN LOWER(NULLIF(TRIM(JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.IssueResuelto'))), '')) IN ('1', 'true', 'yes', 'si', 'sí', 'y') THEN 1
            WHEN LOWER(NULLIF(TRIM(JSON_UNQUOTE(JSON_EXTRACT(cc.context_json, '$.IssueResuelto'))), '')) IN ('0', 'false', 'no', 'n') THEN 0
            ELSE NULL
        END AS issue_resuelto_flag,
        NULLIF(TRIM(cc.completion_message_text), '') AS completion_message_text,
        cc.context_json,
        ROW_NUMBER() OVER (
            PARTITION BY cc.conversation_id
            ORDER BY cc.snapshot_at DESC, cc.id DESC
        ) AS row_num
    FROM conversation_contexts cc
) ranked
WHERE ranked.row_num = 1;

-- =========================================================
-- 4) Message-derived per-conversation metrics
--
-- Exact only when /incoming and /outgoing message ingestion is
-- complete. In current observed data that is true for almost every
-- conversation, but one conversation still looks status-only.
-- =========================================================

CREATE VIEW vw_grafana_conversation_message_metrics_from_messages AS
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
-- 5) Current conversation view
--
-- Design choices:
--   - topic/subtopic remain exact only when present in source columns
--   - motivo_consulta_aprox does NOT fall back to product
--   - product is exposed separately plus a quality label
--   - handoff_to_human_aprox remains approximate by design
--   - resolution stays exact-only; no synthetic close timestamps
-- =========================================================

CREATE VIEW vw_grafana_conversations_current AS
SELECT
    enriched.conversation_id,
    enriched.provider_name,
    enriched.conversation_external_id,
    enriched.customer_id,
    enriched.customer_external_id,
    enriched.contact_external_id,
    enriched.channel,
    enriched.business_channel_id,
    enriched.business_channel_address,
    enriched.current_queue_name,
    enriched.status_current,
    enriched.is_bot_muted,
    enriched.pending_message_count,
    enriched.conversation_started_at,
    enriched.first_user_message_at,
    enriched.first_bot_response_at,
    enriched.first_human_response_at,
    enriched.last_message_at,
    enriched.last_message_sender_type,
    enriched.last_action_author_external_id,
    enriched.resolved_flag,
    CASE
        WHEN enriched.resolved_flag IS NOT NULL THEN 'IssueResuelto'
        ELSE 'not_available'
    END AS resolved_flag_source,
    enriched.resolution_type,
    enriched.closed_by,
    enriched.closed_at,
    enriched.topic,
    enriched.subtopic,
    enriched.product,
    CASE
        WHEN enriched.product IS NULL THEN 'missing'
        WHEN enriched.activity_name IS NOT NULL
         AND LOWER(enriched.product) = LOWER(enriched.activity_name) THEN 'overloaded_matches_activity_name'
        WHEN enriched.ap_actividad IS NOT NULL
         AND LOWER(enriched.product) = LOWER(enriched.ap_actividad) THEN 'overloaded_matches_ap_actividad'
        ELSE 'distinct_unvalidated_value'
    END AS product_data_quality,
    CASE
        WHEN enriched.subtopic IS NOT NULL THEN enriched.subtopic
        WHEN enriched.topic IS NOT NULL THEN enriched.topic
        WHEN enriched.activity_name IS NOT NULL THEN enriched.activity_name
        ELSE NULL
    END AS motivo_consulta_aprox,
    CASE
        WHEN enriched.subtopic IS NOT NULL THEN 'subtopic'
        WHEN enriched.topic IS NOT NULL THEN 'topic'
        WHEN enriched.activity_name IS NOT NULL THEN CONCAT('activity_name_', enriched.activity_name_source)
        ELSE 'not_available'
    END AS motivo_consulta_source_aprox,
    CASE
        WHEN enriched.subtopic IS NOT NULL OR enriched.topic IS NOT NULL THEN 'structured_topic_taxonomy'
        WHEN enriched.activity_name IS NOT NULL THEN 'activity_name_fallback'
        ELSE 'not_available'
    END AS classification_quality,
    enriched.journey_stage,
    enriched.handoff_reason,
    enriched.activity_name,
    enriched.activity_name_source,
    enriched.activity_code,
    enriched.ap_actividad,
    enriched.busqueda_actividad_flag,
    enriched.issue_resuelto_flag,
    enriched.quote_external_id,
    enriched.coverage_external_id,
    enriched.quoted_total_amount,
    enriched.quote_description,
    CASE
        WHEN enriched.quote_external_id IS NOT NULL
          OR enriched.coverage_external_id IS NOT NULL THEN 1
        ELSE 0
    END AS quote_generated_flag,
    enriched.completion_message_text,
    enriched.message_count_observed,
    enriched.message_count_user_observed,
    enriched.message_count_bot_observed,
    enriched.message_count_operator_observed,
    enriched.had_bot_intervention_observed,
    enriched.had_human_intervention_observed,
    enriched.interaction_mode_observed,
    CASE
        WHEN enriched.first_user_message_at IS NOT NULL
         AND enriched.first_bot_response_at IS NOT NULL
         AND enriched.first_bot_response_at >= enriched.first_user_message_at THEN
            TIMESTAMPDIFF(SECOND, enriched.first_user_message_at, enriched.first_bot_response_at)
        ELSE NULL
    END AS time_to_first_bot_response_seconds,
    CASE
        WHEN enriched.first_user_message_at IS NOT NULL
         AND enriched.first_human_response_at IS NOT NULL
         AND enriched.first_human_response_at >= enriched.first_user_message_at THEN
            TIMESTAMPDIFF(SECOND, enriched.first_user_message_at, enriched.first_human_response_at)
        ELSE NULL
    END AS time_to_first_human_response_seconds,
    CASE
        WHEN enriched.first_user_message_at IS NULL
         AND enriched.conversation_started_at IS NOT NULL
         AND enriched.first_bot_response_at IS NOT NULL
         AND enriched.first_bot_response_at >= enriched.conversation_started_at THEN
            TIMESTAMPDIFF(SECOND, enriched.conversation_started_at, enriched.first_bot_response_at)
        ELSE NULL
    END AS time_to_first_bot_response_seconds_aprox,
    CASE
        WHEN enriched.first_user_message_at IS NULL
         AND enriched.conversation_started_at IS NOT NULL
         AND enriched.first_human_response_at IS NOT NULL
         AND enriched.first_human_response_at >= enriched.conversation_started_at THEN
            TIMESTAMPDIFF(SECOND, enriched.conversation_started_at, enriched.first_human_response_at)
        ELSE NULL
    END AS time_to_first_human_response_seconds_aprox,
    CASE
        WHEN enriched.conversation_started_at IS NOT NULL
         AND enriched.closed_at IS NOT NULL
         AND enriched.closed_at >= enriched.conversation_started_at THEN
            TIMESTAMPDIFF(SECOND, enriched.conversation_started_at, enriched.closed_at)
        ELSE NULL
    END AS resolution_time_seconds,
    CASE
        WHEN enriched.first_human_response_at IS NOT NULL
          OR COALESCE(enriched.message_count_operator_observed, 0) > 0 THEN 1
        ELSE 0
    END AS handoff_to_human_aprox,
    CASE
        WHEN enriched.first_human_response_at IS NOT NULL THEN 'first_human_response_at'
        WHEN COALESCE(enriched.message_count_operator_observed, 0) > 0 THEN 'operator_message_observed'
        ELSE 'not_handoff_observed'
    END AS handoff_detection_basis_aprox,
    CASE
        WHEN enriched.closed_at IS NOT NULL THEN 'exact_closed_at'
        WHEN enriched.resolved_flag IS NOT NULL THEN 'resolved_flag_without_closed_at'
        ELSE 'not_available'
    END AS resolution_data_quality,
    CASE
        WHEN COALESCE(enriched.message_count_user_observed, 0) > 0
         AND (
            COALESCE(enriched.message_count_bot_observed, 0) > 0
            OR COALESCE(enriched.message_count_operator_observed, 0) > 0
         ) THEN 'message_history_observed'
        ELSE 'status_or_partial_history'
    END AS message_history_quality,
    CASE
        WHEN enriched.first_user_message_at IS NOT NULL
         AND enriched.first_human_response_at IS NOT NULL
         AND enriched.first_human_response_at < enriched.first_user_message_at THEN 'human_before_user'
        WHEN enriched.first_user_message_at IS NOT NULL
         AND enriched.first_bot_response_at IS NOT NULL
         AND enriched.first_bot_response_at < enriched.first_user_message_at THEN 'bot_before_user'
        WHEN enriched.conversation_started_at IS NOT NULL
         AND enriched.last_message_at IS NOT NULL
         AND enriched.last_message_at < enriched.conversation_started_at THEN 'last_message_before_start'
        WHEN enriched.conversation_started_at IS NOT NULL
         AND enriched.closed_at IS NOT NULL
         AND enriched.closed_at < enriched.conversation_started_at THEN 'closed_before_start'
        ELSE 'ok'
    END AS timeline_quality
FROM (
    SELECT
        cb.conversation_id,
        cb.provider_name,
        cb.conversation_external_id,
        cb.customer_id,
        cb.customer_external_id,
        cb.contact_external_id,
        cb.channel,
        cb.business_channel_id,
        cb.business_channel_address,
        cb.current_queue_name,
        cb.status_current,
        cb.is_bot_muted,
        cb.pending_message_count,
        cb.conversation_started_at,
        cb.first_user_message_at,
        cb.first_bot_response_at,
        cb.first_human_response_at,
        cb.last_message_at,
        cb.last_message_sender_type,
        cb.last_action_author_external_id,
        COALESCE(cb.resolved_flag_raw, lc.issue_resuelto_flag) AS resolved_flag,
        cb.resolution_type,
        cb.closed_by,
        cb.closed_at,
        COALESCE(cb.conversation_topic, lc.topic) AS topic,
        COALESCE(cb.conversation_subtopic, lc.subtopic) AS subtopic,
        COALESCE(cb.conversation_product, lc.product) AS product,
        cb.journey_stage,
        cb.handoff_reason,
        lc.activity_name,
        lc.activity_name_source,
        lc.activity_code,
        lc.ap_actividad,
        lc.busqueda_actividad_flag,
        lc.issue_resuelto_flag,
        lc.quote_external_id,
        lc.coverage_external_id,
        lc.quoted_total_amount,
        lc.quote_description,
        lc.completion_message_text,
        mm.message_count_observed,
        mm.message_count_user_observed,
        mm.message_count_bot_observed,
        mm.message_count_operator_observed,
        mm.had_bot_intervention_observed,
        mm.had_human_intervention_observed,
        mm.interaction_mode_observed
    FROM (
        SELECT
            c.id AS conversation_id,
            c.provider_name,
            c.conversation_external_id,
            c.customer_id,
            cu.customer_external_id,
            cu.contact_external_id,
            c.channel,
            NULLIF(TRIM(c.business_channel_id), '') AS business_channel_id,
            NULLIF(TRIM(c.business_channel_address), '') AS business_channel_address,
            NULLIF(TRIM(c.current_queue_name), '') AS current_queue_name,
            NULLIF(TRIM(c.status_current), '') AS status_current,
            c.is_bot_muted,
            c.pending_message_count,
            c.conversation_started_at,
            c.first_user_message_at,
            c.first_bot_response_at,
            c.first_human_response_at,
            c.last_message_at,
            NULLIF(TRIM(c.last_message_sender_type), '') AS last_message_sender_type,
            NULLIF(TRIM(c.last_action_author_external_id), '') AS last_action_author_external_id,
            c.resolved_flag AS resolved_flag_raw,
            NULLIF(TRIM(c.resolution_type), '') AS resolution_type,
            NULLIF(TRIM(c.closed_by), '') AS closed_by,
            c.closed_at,
            NULLIF(TRIM(c.topic), '') AS conversation_topic,
            NULLIF(TRIM(c.subtopic), '') AS conversation_subtopic,
            NULLIF(TRIM(c.product), '') AS conversation_product,
            NULLIF(TRIM(c.journey_stage), '') AS journey_stage,
            NULLIF(TRIM(c.handoff_reason), '') AS handoff_reason
        FROM conversations c
        JOIN customers cu
          ON cu.id = c.customer_id
    ) cb
    LEFT JOIN vw_grafana_conversation_latest_context lc
      ON lc.conversation_id = cb.conversation_id
    LEFT JOIN vw_grafana_conversation_message_metrics_from_messages mm
      ON mm.conversation_id = cb.conversation_id
) enriched;

-- =========================================================
-- 6) Aggregates and dependent views
-- =========================================================

CREATE VIEW vw_grafana_conversations_daily AS
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
    SUM(CASE WHEN quote_generated_flag = 1 THEN 1 ELSE 0 END) AS quoted_conversation_count,
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

CREATE VIEW vw_grafana_queue_channel_status_current AS
SELECT
    provider_name,
    channel,
    COALESCE(current_queue_name, 'unknown') AS queue_name,
    COALESCE(status_current, 'unknown') AS status_current,
    COUNT(*) AS conversation_count,
    SUM(CASE WHEN is_bot_muted = 1 THEN 1 ELSE 0 END) AS bot_muted_count,
    SUM(CASE WHEN pending_message_count > 0 THEN 1 ELSE 0 END) AS conversations_with_pending_messages,
    SUM(CASE WHEN handoff_to_human_aprox = 1 THEN 1 ELSE 0 END) AS handoff_to_human_count_aprox,
    SUM(CASE WHEN quote_generated_flag = 1 THEN 1 ELSE 0 END) AS quoted_conversation_count
FROM vw_grafana_conversations_current
GROUP BY
    provider_name,
    channel,
    COALESCE(current_queue_name, 'unknown'),
    COALESCE(status_current, 'unknown');

CREATE VIEW vw_grafana_resolution_current AS
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
    product_data_quality,
    activity_name,
    activity_name_source,
    motivo_consulta_aprox,
    motivo_consulta_source_aprox,
    classification_quality,
    conversation_started_at,
    first_user_message_at,
    first_bot_response_at,
    first_human_response_at,
    closed_at,
    resolved_flag,
    resolved_flag_source,
    resolution_type,
    closed_by,
    resolution_time_seconds,
    resolution_data_quality,
    timeline_quality,
    time_to_first_bot_response_seconds,
    time_to_first_human_response_seconds,
    time_to_first_bot_response_seconds_aprox,
    time_to_first_human_response_seconds_aprox,
    handoff_to_human_aprox,
    handoff_detection_basis_aprox,
    handoff_reason
FROM vw_grafana_conversations_current;

CREATE VIEW vw_grafana_handoff_to_human_aprox AS
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
    product_data_quality,
    activity_name,
    activity_name_source,
    motivo_consulta_aprox,
    motivo_consulta_source_aprox,
    interaction_mode_observed,
    conversation_started_at,
    first_human_response_at,
    message_count_operator_observed,
    handoff_to_human_aprox,
    handoff_detection_basis_aprox
FROM vw_grafana_conversations_current
WHERE handoff_to_human_aprox = 1;

CREATE VIEW vw_grafana_activity_motive_breakdown_current AS
SELECT
    provider_name,
    channel,
    COALESCE(current_queue_name, 'unknown') AS queue_name,
    COALESCE(status_current, 'unknown') AS status_current,
    COALESCE(activity_name, 'unknown') AS activity_name,
    COALESCE(activity_name_source, 'not_available') AS activity_name_source,
    COALESCE(motivo_consulta_aprox, 'unknown') AS motivo_consulta_aprox,
    COALESCE(motivo_consulta_source_aprox, 'not_available') AS motivo_consulta_source_aprox,
    COALESCE(topic, 'unknown') AS topic,
    COALESCE(subtopic, 'unknown') AS subtopic,
    COALESCE(product, 'unknown') AS product,
    COALESCE(product_data_quality, 'missing') AS product_data_quality,
    COUNT(*) AS conversation_count,
    SUM(CASE WHEN handoff_to_human_aprox = 1 THEN 1 ELSE 0 END) AS handoff_to_human_count_aprox,
    SUM(CASE WHEN resolved_flag = 1 THEN 1 ELSE 0 END) AS resolved_count,
    SUM(CASE WHEN quote_generated_flag = 1 THEN 1 ELSE 0 END) AS quoted_conversation_count,
    SUM(CASE WHEN interaction_mode_observed = 'bot_only' THEN 1 ELSE 0 END) AS bot_only_conversation_count,
    SUM(CASE WHEN interaction_mode_observed = 'human_only' THEN 1 ELSE 0 END) AS human_only_conversation_count,
    SUM(CASE WHEN interaction_mode_observed = 'mixed' THEN 1 ELSE 0 END) AS mixed_conversation_count,
    AVG(time_to_first_human_response_seconds) AS avg_time_to_first_human_response_seconds,
    AVG(time_to_first_human_response_seconds_aprox) AS avg_time_to_first_human_response_seconds_aprox
FROM vw_grafana_conversations_current
GROUP BY
    provider_name,
    channel,
    COALESCE(current_queue_name, 'unknown'),
    COALESCE(status_current, 'unknown'),
    COALESCE(activity_name, 'unknown'),
    COALESCE(activity_name_source, 'not_available'),
    COALESCE(motivo_consulta_aprox, 'unknown'),
    COALESCE(motivo_consulta_source_aprox, 'not_available'),
    COALESCE(topic, 'unknown'),
    COALESCE(subtopic, 'unknown'),
    COALESCE(product, 'unknown'),
    COALESCE(product_data_quality, 'missing');
