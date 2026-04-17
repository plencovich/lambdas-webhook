from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from typing import Any


@dataclass(frozen=True, slots=True)
class StatusCustomer:
    provider_name: str
    customer_external_id: str
    contact_external_id: str | None
    channel: str
    business_channel_id: str | None
    business_channel_address: str | None
    customer_first_name: str | None
    customer_last_name: str | None
    customer_country_code: str | None
    customer_locale: str | None
    customer_gender: str | None
    customer_created_at: datetime | None


@dataclass(frozen=True, slots=True)
class StatusOperator:
    provider_name: str
    operator_external_id: str
    operator_name: str | None
    operator_email: str | None
    operator_role: str | None = None


@dataclass(frozen=True, slots=True)
class StatusConversation:
    provider_name: str
    conversation_external_id: str
    channel: str
    business_channel_id: str | None
    business_channel_address: str | None
    conversation_started_at: datetime | None
    first_user_message_at: datetime | None
    first_bot_response_at: datetime | None
    first_human_response_at: datetime | None
    last_message_at: datetime | None
    last_message_sender_type: str | None
    current_queue_name: str | None
    is_bot_muted: bool
    pending_message_count: int
    last_action_author_external_id: str | None
    status_current: str | None
    topic: str | None
    subtopic: str | None
    product: str | None
    journey_stage: str | None = None
    handoff_reason: str | None = None
    resolved_flag: bool | None = None
    resolution_type: str | None = None
    closed_by: str | None = None
    closed_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class StatusMessage:
    provider_name: str
    message_external_id: str
    message_at: datetime
    direction: str
    sender_type: str
    sender_name: str | None
    message_text: str | None
    is_button: bool
    button_label: str | None
    is_customer_message: bool
    has_attachment: bool
    attachment_type: str | None
    attachment_url: str | None
    intent_name: str | None
    queue_name: str | None
    delivery_status: str | None
    delivery_status_at: datetime | None
    client_payload: Mapping[str, Any] | None


@dataclass(frozen=True, slots=True)
class StatusSnapshot:
    provider_name: str
    snapshot_at: datetime
    status_current: str | None
    is_bot_muted: bool
    pending_message_count: int
    last_seen_at: datetime | None
    last_user_message_received_at: datetime | None
    last_user_message_read_at: datetime | None
    last_action_author_external_id: str | None
    queue_name: str | None
    executed_intents_json: list[Any] | None
    last_message_external_id: str | None
    last_message_at: datetime | None
    last_message_sender_type: str | None
    last_message_sender_name: str | None
    last_message_text: str | None
    operator_external_id: str | None
    operator_name: str | None
    operator_email: str | None


@dataclass(frozen=True, slots=True)
class StatusContext:
    provider_name: str
    snapshot_at: datetime
    product: str | None
    topic: str | None
    subtopic: str | None
    quote_external_id: str | None
    coverage_external_id: str | None
    quoted_total_amount: Decimal | None
    quote_description: str | None
    activity_name: str | None
    completion_message_text: str | None
    context_json: Mapping[str, Any] | None


@dataclass(frozen=True, slots=True)
class StatusWebhookEvent:
    provider_name: str
    source_endpoint: str
    event_type: str
    external_event_key: str
    conversation_external_id: str
    customer_external_id: str
    received_at: datetime
    request_id: str | None
    headers: Mapping[str, str]
    raw_payload: Mapping[str, Any]
    customer: StatusCustomer
    conversation: StatusConversation
    snapshot: StatusSnapshot
    context: StatusContext
    message: StatusMessage | None = None
    operator: StatusOperator | None = None
    trace_context: Mapping[str, Any] = field(default_factory=dict)
