-- =========================================================
-- Initial DDL - Generic conversational analytics schema
-- Target: MySQL 8.x / AWS RDS
-- =========================================================

SET NAMES utf8mb4;

-- =========================================================
-- 1) RAW WEBHOOK EVENTS
-- =========================================================
CREATE TABLE IF NOT EXISTS webhook_events_raw (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    provider_name VARCHAR(50) NOT NULL,
    source_endpoint VARCHAR(100) NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    external_event_key VARCHAR(200) NOT NULL,
    conversation_external_id VARCHAR(150) NULL,
    customer_external_id VARCHAR(100) NULL,
    received_at DATETIME(3) NOT NULL,
    processed_at DATETIME(3) NULL,
    processing_status VARCHAR(50) NOT NULL DEFAULT 'pending',
    processing_error TEXT NULL,
    raw_payload_json JSON NOT NULL,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (id),
    UNIQUE KEY uq_webhook_events_raw_provider_event_key (provider_name, external_event_key),
    KEY idx_webhook_events_raw_received_at (received_at),
    KEY idx_webhook_events_raw_processing_status (processing_status),
    KEY idx_webhook_events_raw_conversation_external_id (conversation_external_id),
    KEY idx_webhook_events_raw_customer_external_id (customer_external_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- =========================================================
-- 2) CUSTOMERS
-- =========================================================
CREATE TABLE IF NOT EXISTS customers (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    provider_name VARCHAR(50) NOT NULL,
    customer_external_id VARCHAR(100) NOT NULL,
    contact_external_id VARCHAR(100) NULL,
    channel VARCHAR(50) NOT NULL,
    business_channel_id VARCHAR(150) NULL,
    business_channel_address VARCHAR(100) NULL,
    customer_first_name VARCHAR(150) NULL,
    customer_last_name VARCHAR(150) NULL,
    customer_country_code VARCHAR(10) NULL,
    customer_locale VARCHAR(20) NULL,
    customer_gender VARCHAR(20) NULL,
    customer_created_at DATETIME(3) NULL,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (id),
    UNIQUE KEY uq_customers_provider_customer_external_id (provider_name, customer_external_id),
    KEY idx_customers_contact_external_id (contact_external_id),
    KEY idx_customers_channel (channel),
    KEY idx_customers_business_channel_id (business_channel_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- =========================================================
-- 3) OPERATORS
-- =========================================================
CREATE TABLE IF NOT EXISTS operators (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    provider_name VARCHAR(50) NOT NULL,
    operator_external_id VARCHAR(100) NOT NULL,
    operator_name VARCHAR(150) NULL,
    operator_email VARCHAR(200) NULL,
    operator_role VARCHAR(100) NULL,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (id),
    UNIQUE KEY uq_operators_provider_operator_external_id (provider_name, operator_external_id),
    KEY idx_operators_email (operator_email),
    KEY idx_operators_name (operator_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- =========================================================
-- 4) CONVERSATIONS
-- =========================================================
CREATE TABLE IF NOT EXISTS conversations (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    provider_name VARCHAR(50) NOT NULL,
    conversation_external_id VARCHAR(150) NOT NULL,
    customer_id BIGINT UNSIGNED NOT NULL,
    channel VARCHAR(50) NOT NULL,
    business_channel_id VARCHAR(150) NULL,
    business_channel_address VARCHAR(100) NULL,
    conversation_started_at DATETIME(3) NULL,
    first_user_message_at DATETIME(3) NULL,
    first_bot_response_at DATETIME(3) NULL,
    first_human_response_at DATETIME(3) NULL,
    last_message_at DATETIME(3) NULL,
    last_message_sender_type VARCHAR(50) NULL,
    current_queue_name VARCHAR(150) NULL,
    is_bot_muted TINYINT(1) NOT NULL DEFAULT 0,
    pending_message_count INT UNSIGNED NOT NULL DEFAULT 0,
    last_action_author_external_id VARCHAR(100) NULL,
    status_current VARCHAR(50) NULL,
    topic VARCHAR(100) NULL,
    subtopic VARCHAR(100) NULL,
    product VARCHAR(100) NULL,
    journey_stage VARCHAR(100) NULL,
    handoff_reason VARCHAR(100) NULL,
    resolved_flag TINYINT(1) NULL,
    resolution_type VARCHAR(50) NULL,
    closed_by VARCHAR(50) NULL,
    closed_at DATETIME(3) NULL,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (id),
    UNIQUE KEY uq_conversations_provider_conversation_external_id (provider_name, conversation_external_id),
    KEY idx_conversations_customer_id (customer_id),
    KEY idx_conversations_channel (channel),
    KEY idx_conversations_status_current (status_current),
    KEY idx_conversations_topic (topic),
    KEY idx_conversations_product (product),
    KEY idx_conversations_started_at (conversation_started_at),
    KEY idx_conversations_last_message_at (last_message_at),

    CONSTRAINT fk_conversations_customer
        FOREIGN KEY (customer_id) REFERENCES customers (id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- =========================================================
-- 5) MESSAGES
-- =========================================================
CREATE TABLE IF NOT EXISTS messages (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    provider_name VARCHAR(50) NOT NULL,
    message_external_id VARCHAR(150) NOT NULL,
    conversation_id BIGINT UNSIGNED NOT NULL,
    customer_id BIGINT UNSIGNED NOT NULL,
    operator_id BIGINT UNSIGNED NULL,
    message_at DATETIME(3) NOT NULL,
    direction VARCHAR(10) NOT NULL,
    sender_type VARCHAR(50) NOT NULL,
    sender_name VARCHAR(150) NULL,
    message_text TEXT NULL,
    is_button TINYINT(1) NOT NULL DEFAULT 0,
    button_label VARCHAR(200) NULL,
    is_customer_message TINYINT(1) NOT NULL DEFAULT 0,
    has_attachment TINYINT(1) NOT NULL DEFAULT 0,
    attachment_type VARCHAR(50) NULL,
    attachment_url TEXT NULL,
    intent_name VARCHAR(150) NULL,
    queue_name VARCHAR(150) NULL,
    delivery_status VARCHAR(50) NULL,
    delivery_status_at DATETIME(3) NULL,
    client_payload JSON NULL,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (id),
    UNIQUE KEY uq_messages_provider_message_external_id (provider_name, message_external_id),
    KEY idx_messages_conversation_id (conversation_id),
    KEY idx_messages_customer_id (customer_id),
    KEY idx_messages_operator_id (operator_id),
    KEY idx_messages_message_at (message_at),
    KEY idx_messages_sender_type (sender_type),
    KEY idx_messages_direction (direction),
    KEY idx_messages_intent_name (intent_name),
    KEY idx_messages_queue_name (queue_name),
    KEY idx_messages_delivery_status (delivery_status),

    CONSTRAINT fk_messages_conversation
        FOREIGN KEY (conversation_id) REFERENCES conversations (id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,

    CONSTRAINT fk_messages_customer
        FOREIGN KEY (customer_id) REFERENCES customers (id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE,

    CONSTRAINT fk_messages_operator
        FOREIGN KEY (operator_id) REFERENCES operators (id)
        ON DELETE SET NULL
        ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- =========================================================
-- 6) CONVERSATION SNAPSHOTS
-- =========================================================
CREATE TABLE IF NOT EXISTS conversation_snapshots (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    provider_name VARCHAR(50) NOT NULL,
    conversation_id BIGINT UNSIGNED NOT NULL,
    customer_id BIGINT UNSIGNED NOT NULL,
    snapshot_at DATETIME(3) NOT NULL,
    status_current VARCHAR(50) NULL,
    is_bot_muted TINYINT(1) NOT NULL DEFAULT 0,
    pending_message_count INT UNSIGNED NOT NULL DEFAULT 0,
    last_seen_at DATETIME(3) NULL,
    last_user_message_received_at DATETIME(3) NULL,
    last_user_message_read_at DATETIME(3) NULL,
    last_action_author_external_id VARCHAR(100) NULL,
    queue_name VARCHAR(150) NULL,
    executed_intents_json JSON NULL,
    last_message_external_id VARCHAR(150) NULL,
    last_message_at DATETIME(3) NULL,
    last_message_sender_type VARCHAR(50) NULL,
    last_message_sender_name VARCHAR(150) NULL,
    last_message_text TEXT NULL,
    operator_external_id VARCHAR(100) NULL,
    operator_name VARCHAR(150) NULL,
    operator_email VARCHAR(200) NULL,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (id),
    KEY idx_conversation_snapshots_conversation_id (conversation_id),
    KEY idx_conversation_snapshots_customer_id (customer_id),
    KEY idx_conversation_snapshots_snapshot_at (snapshot_at),
    KEY idx_conversation_snapshots_status_current (status_current),
    KEY idx_conversation_snapshots_queue_name (queue_name),
    KEY idx_conversation_snapshots_last_message_external_id (last_message_external_id),

    CONSTRAINT fk_conversation_snapshots_conversation
        FOREIGN KEY (conversation_id) REFERENCES conversations (id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,

    CONSTRAINT fk_conversation_snapshots_customer
        FOREIGN KEY (customer_id) REFERENCES customers (id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- =========================================================
-- 7) CONVERSATION CONTEXTS
-- =========================================================
CREATE TABLE IF NOT EXISTS conversation_contexts (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    provider_name VARCHAR(50) NOT NULL,
    conversation_id BIGINT UNSIGNED NOT NULL,
    customer_id BIGINT UNSIGNED NOT NULL,
    snapshot_at DATETIME(3) NOT NULL,
    product VARCHAR(100) NULL,
    topic VARCHAR(100) NULL,
    subtopic VARCHAR(100) NULL,
    quote_external_id VARCHAR(150) NULL,
    coverage_external_id VARCHAR(150) NULL,
    quoted_total_amount DECIMAL(14,2) NULL,
    quote_description TEXT NULL,
    activity_name VARCHAR(200) NULL,
    completion_message_text TEXT NULL,
    context_json JSON NULL,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (id),
    KEY idx_conversation_contexts_conversation_id (conversation_id),
    KEY idx_conversation_contexts_customer_id (customer_id),
    KEY idx_conversation_contexts_snapshot_at (snapshot_at),
    KEY idx_conversation_contexts_product (product),
    KEY idx_conversation_contexts_topic (topic),
    KEY idx_conversation_contexts_quote_external_id (quote_external_id),

    CONSTRAINT fk_conversation_contexts_conversation
        FOREIGN KEY (conversation_id) REFERENCES conversations (id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,

    CONSTRAINT fk_conversation_contexts_customer
        FOREIGN KEY (customer_id) REFERENCES customers (id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- =========================================================
-- 8) CONVERSATION METRICS
-- =========================================================
CREATE TABLE IF NOT EXISTS conversation_metrics (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    conversation_id BIGINT UNSIGNED NOT NULL,
    customer_id BIGINT UNSIGNED NOT NULL,
    channel VARCHAR(50) NOT NULL,
    topic VARCHAR(100) NULL,
    subtopic VARCHAR(100) NULL,
    product VARCHAR(100) NULL,
    had_bot_intervention TINYINT(1) NOT NULL DEFAULT 0,
    had_human_intervention TINYINT(1) NOT NULL DEFAULT 0,
    interaction_mode VARCHAR(50) NULL,
    message_count_user INT UNSIGNED NOT NULL DEFAULT 0,
    message_count_bot INT UNSIGNED NOT NULL DEFAULT 0,
    message_count_operator INT UNSIGNED NOT NULL DEFAULT 0,
    time_to_first_bot_response_seconds INT UNSIGNED NULL,
    time_to_first_human_response_seconds INT UNSIGNED NULL,
    resolution_time_seconds INT UNSIGNED NULL,
    resolved_flag TINYINT(1) NULL,
    resolution_type VARCHAR(50) NULL,
    closed_by VARCHAR(50) NULL,
    handoff_reason VARCHAR(100) NULL,
    queue_first VARCHAR(150) NULL,
    queue_last VARCHAR(150) NULL,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

    PRIMARY KEY (id),
    UNIQUE KEY uq_conversation_metrics_conversation_id (conversation_id),
    KEY idx_conversation_metrics_customer_id (customer_id),
    KEY idx_conversation_metrics_channel (channel),
    KEY idx_conversation_metrics_topic (topic),
    KEY idx_conversation_metrics_product (product),
    KEY idx_conversation_metrics_resolved_flag (resolved_flag),
    KEY idx_conversation_metrics_resolution_type (resolution_type),
    KEY idx_conversation_metrics_closed_by (closed_by),

    CONSTRAINT fk_conversation_metrics_conversation
        FOREIGN KEY (conversation_id) REFERENCES conversations (id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,

    CONSTRAINT fk_conversation_metrics_customer
        FOREIGN KEY (customer_id) REFERENCES customers (id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
