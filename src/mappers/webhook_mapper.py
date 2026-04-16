from collections.abc import Mapping
from datetime import UTC, datetime
from typing import Any

from models.webhook_event import WebhookEnvelope
from utils.config import get_app_config
from utils.events import get_request_id


class WebhookMapper:
    def to_envelope(
        self,
        source_endpoint: str,
        event: Mapping[str, Any],
        payload: Mapping[str, Any],
        context: Any | None = None,
    ) -> WebhookEnvelope:
        headers = _normalize_headers(event.get("headers") or {})

        return WebhookEnvelope(
            provider_name=get_app_config().provider_name,
            source_endpoint=source_endpoint,
            payload=payload,
            received_at=datetime.now(UTC),
            request_id=get_request_id(event, context),
            event_type=_extract_event_type(payload),
            idempotency_key=_extract_idempotency_key(headers, payload),
            headers=headers,
        )


def _normalize_headers(headers: Mapping[str, Any]) -> dict[str, str]:
    return {str(key).lower(): str(value) for key, value in headers.items()}


def _extract_event_type(payload: Mapping[str, Any]) -> str:
    event_type = payload.get("type") or payload.get("eventType") or payload.get("event_type")
    return str(event_type) if event_type else "unknown"


def _extract_idempotency_key(
    headers: Mapping[str, str],
    payload: Mapping[str, Any],
) -> str | None:
    for header_name in ("idempotency-key", "x-event-id", "x-botmaker-event-id"):
        if headers.get(header_name):
            return headers[header_name]

    for field_name in ("eventId", "event_id", "messageId", "message_id", "id"):
        if payload.get(field_name):
            return str(payload[field_name])

    return None
