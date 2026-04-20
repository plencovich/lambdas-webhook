from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from models.status_event import (
    StatusConversation,
    StatusCustomer,
    StatusMessage,
    StatusOperator,
)


@dataclass(frozen=True, slots=True)
class OutgoingWebhookEvent:
    provider_name: str
    source_endpoint: str
    event_type: str
    external_event_key: str
    conversation_external_id: str
    customer_external_id: str
    message_external_id: str
    received_at: datetime
    request_id: str | None
    headers: Mapping[str, str]
    raw_payload: Mapping[str, Any]
    customer: StatusCustomer
    conversation: StatusConversation
    message: StatusMessage
    operator: StatusOperator | None = None
    trace_context: Mapping[str, Any] = field(default_factory=dict)
