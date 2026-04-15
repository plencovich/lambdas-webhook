from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any


@dataclass(frozen=True, slots=True)
class WebhookEnvelope:
    provider_name: str
    source_endpoint: str
    payload: Mapping[str, Any]
    received_at: datetime
    request_id: str | None = None
    event_type: str = "unknown"
    idempotency_key: str | None = None
    headers: Mapping[str, str] = field(default_factory=dict)
