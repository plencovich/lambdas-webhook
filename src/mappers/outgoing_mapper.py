import hashlib
import json
from collections.abc import Mapping
from datetime import UTC, datetime
from typing import Any

from mappers.common import normalize_optional_text
from models.outgoing_event import OutgoingWebhookEvent
from models.status_event import (
    StatusConversation,
    StatusCustomer,
    StatusMessage,
    StatusOperator,
)
from models.webhook_event import WebhookEnvelope
from utils.exceptions import ValidationError

OUTGOING_EVENT_TYPE = "outgoing_message"


class OutgoingPayloadMapper:
    def to_outgoing_event(self, envelope: WebhookEnvelope) -> OutgoingWebhookEvent:
        payload = envelope.payload
        received_at = _to_utc_naive(envelope.received_at) or datetime.now(UTC).replace(tzinfo=None)

        message_external_id = _message_external_id(payload)
        conversation_external_id = _first_text(payload, "sessionId", "conversationId", "conversation_id")
        customer_external_id = _first_text(payload, "customerId")
        message_at = _first_datetime(payload, "date")
        sender_type = _sender_type(payload)
        channel = _first_text(payload, "chatPlatform", "channel")
        message_text = _first_text(payload, "message")
        attachment_url = _attachment_url(payload)

        if not message_external_id:
            raise ValidationError("Outgoing payload is missing message identifier")
        if not conversation_external_id:
            raise ValidationError("Outgoing payload is missing sessionId")
        if not customer_external_id:
            raise ValidationError("Outgoing payload is missing customerId")
        if message_at is None:
            raise ValidationError("Outgoing payload is missing date")
        if sender_type is None:
            raise ValidationError("Outgoing payload is missing from")
        if not channel:
            raise ValidationError("Outgoing payload is missing chatPlatform")
        if not (message_text or attachment_url):
            raise ValidationError("Outgoing payload is missing message content")

        contact_external_id = _first_text(payload, "contactId")
        business_channel_address = _first_text(payload, "WHATSAPP_NUMBER", "businessChannelAddress")
        business_channel_id = _first_text(payload, "chatChannelId", "businessChannelId")
        queue_name = _first_text(payload, "queue")
        session_creation_time = _first_datetime(payload, "sessionCreationTime")
        operator = _operator(envelope.provider_name, payload, sender_type)
        has_attachment = bool(attachment_url) or _bool(payload.get("hasAttachment"))
        sender_name = _sender_name(payload, sender_type)

        customer = StatusCustomer(
            provider_name=envelope.provider_name,
            customer_external_id=customer_external_id,
            contact_external_id=contact_external_id,
            channel=channel,
            business_channel_id=business_channel_id,
            business_channel_address=business_channel_address,
            customer_first_name=None,
            customer_last_name=None,
            customer_country_code=None,
            customer_locale=None,
            customer_gender=None,
            customer_created_at=None,
        )

        conversation = StatusConversation(
            provider_name=envelope.provider_name,
            conversation_external_id=conversation_external_id,
            channel=channel,
            business_channel_id=business_channel_id,
            business_channel_address=business_channel_address,
            conversation_started_at=session_creation_time,
            first_user_message_at=None,
            first_bot_response_at=message_at if sender_type == "bot" else None,
            first_human_response_at=message_at if sender_type == "operator" else None,
            last_message_at=message_at,
            last_message_sender_type=sender_type,
            current_queue_name=queue_name,
            is_bot_muted=False,
            pending_message_count=0,
            last_action_author_external_id=operator.operator_external_id if operator else None,
            status_current=None,
            topic=None,
            subtopic=None,
            product=None,
        )

        message = StatusMessage(
            provider_name=envelope.provider_name,
            message_external_id=message_external_id,
            message_at=message_at,
            direction="outbound",
            sender_type=sender_type,
            sender_name=sender_name,
            message_text=message_text,
            is_button=_bool(payload.get("isButton")),
            button_label=_first_text(payload, "buttonName"),
            is_customer_message=False,
            has_attachment=has_attachment,
            attachment_type=_attachment_type(payload, attachment_url),
            attachment_url=attachment_url,
            intent_name=None,
            queue_name=queue_name,
            delivery_status=None,
            delivery_status_at=None,
            client_payload={
                "outgoing_message": {
                    key: value
                    for key, value in payload.items()
                    if key
                    in {
                        "_id_",
                        "date",
                        "from",
                        "fromName",
                        "message",
                        "isButton",
                        "buttonName",
                        "hasAttachment",
                        "image",
                        "audio",
                        "file",
                        "attachmentUrl",
                        "fileUrl",
                        "mediaUrl",
                        "operatorId",
                        "operatorName",
                        "operatorEmail",
                        "queue",
                        "sessionId",
                        "sessionCreationTime",
                        "customerId",
                        "contactId",
                        "chatPlatform",
                        "WHATSAPP_NUMBER",
                    }
                }
            },
        )

        external_event_key = build_outgoing_external_event_key(
            provider_name=envelope.provider_name,
            source_endpoint=envelope.source_endpoint,
            message_external_id=message_external_id,
            conversation_external_id=conversation_external_id,
            customer_external_id=customer_external_id,
            message_at=message_at,
            sender_type=sender_type,
            operator_external_id=operator.operator_external_id if operator else None,
            message_text=message.message_text,
            attachment_url=attachment_url,
        )

        return OutgoingWebhookEvent(
            provider_name=envelope.provider_name,
            source_endpoint=envelope.source_endpoint,
            event_type=OUTGOING_EVENT_TYPE,
            external_event_key=external_event_key,
            conversation_external_id=conversation_external_id,
            customer_external_id=customer_external_id,
            message_external_id=message_external_id,
            received_at=received_at,
            request_id=envelope.request_id,
            headers=envelope.headers,
            raw_payload=payload,
            customer=customer,
            conversation=conversation,
            message=message,
            operator=operator,
            trace_context={
                "message_external_id": message_external_id,
                "conversation_external_id": conversation_external_id,
                "customer_external_id": customer_external_id,
                "operator_external_id": operator.operator_external_id if operator else None,
                "channel": channel,
                "sender_type": sender_type,
                "queue_name": queue_name,
            },
        )


def build_outgoing_external_event_key(
    *,
    provider_name: str,
    source_endpoint: str,
    message_external_id: str,
    conversation_external_id: str,
    customer_external_id: str,
    message_at: datetime,
    sender_type: str,
    operator_external_id: str | None,
    message_text: str | None,
    attachment_url: str | None,
) -> str:
    if not message_external_id.startswith("fallback:"):
        return f"{source_endpoint}:v1:{provider_name}:message:{message_external_id}"

    identity = {
        "provider_name": provider_name,
        "source_endpoint": source_endpoint,
        "conversation_external_id": conversation_external_id,
        "customer_external_id": customer_external_id,
        "message_at": message_at.isoformat(timespec="milliseconds"),
        "sender_type": sender_type,
        "operator_external_id": operator_external_id,
        "message_text": message_text,
        "attachment_url": attachment_url,
    }
    digest = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return f"{source_endpoint}:v1:{provider_name}:fallback:{digest}"


def _message_external_id(payload: Mapping[str, Any]) -> str | None:
    explicit = _first_text(payload, "_id_", "messageId", "message_id")
    if explicit:
        return explicit

    conversation_external_id = _first_text(payload, "sessionId", "conversationId", "conversation_id")
    customer_external_id = _first_text(payload, "customerId")
    message_at = _first_text(payload, "date")
    sender = _first_text(payload, "from")
    operator_external_id = _first_text(payload, "operatorId")
    message_text = _first_text(payload, "message")
    attachment_url = _attachment_url(payload)
    if not (
        conversation_external_id
        and customer_external_id
        and message_at
        and sender
        and (message_text or attachment_url)
    ):
        return None

    identity = {
        "conversation_external_id": conversation_external_id,
        "customer_external_id": customer_external_id,
        "message_at": message_at,
        "sender": sender,
        "operator_external_id": operator_external_id,
        "message_text": message_text,
        "attachment_url": attachment_url,
    }
    digest = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return f"fallback:{digest[:32]}"


def _operator(
    provider_name: str,
    payload: Mapping[str, Any],
    sender_type: str | None,
) -> StatusOperator | None:
    if sender_type != "operator":
        return None

    operator_external_id = (
        _first_text(payload, "operatorId")
        or _first_text(payload, "operatorEmail")
        or _first_text(payload, "operatorName", "fromName")
    )
    if not operator_external_id:
        return None

    return StatusOperator(
        provider_name=provider_name,
        operator_external_id=operator_external_id,
        operator_name=_first_text(payload, "operatorName", "fromName"),
        operator_email=_first_text(payload, "operatorEmail"),
    )


def _sender_type(payload: Mapping[str, Any]) -> str | None:
    sender = (_first_text(payload, "from") or "").lower()
    if sender in {"bot", "operator"}:
        return sender
    if sender in {"user", "customer"}:
        return "customer"
    if _first_text(payload, "operatorId", "operatorEmail"):
        return "operator"
    return sender or None


def _sender_name(payload: Mapping[str, Any], sender_type: str | None) -> str | None:
    if sender_type == "operator":
        return _first_text(payload, "operatorName", "fromName")
    return _first_text(payload, "fromName")


def _attachment_url(payload: Mapping[str, Any]) -> str | None:
    return _first_text(payload, "image", "audio", "file", "attachmentUrl", "fileUrl", "mediaUrl")


def _attachment_type(payload: Mapping[str, Any], attachment_url: str | None) -> str | None:
    if not attachment_url:
        return None
    if _first_text(payload, "image"):
        return "image"
    if _first_text(payload, "audio"):
        return "audio"
    if _first_text(payload, "file", "fileUrl"):
        return "file"
    return _first_text(payload, "attachmentType", "mediaType") or "attachment"


def _first_text(payload: Mapping[str, Any], *keys: str) -> str | None:
    for key in keys:
        value = _text(payload.get(key))
        if value:
            return value
    return None


def _first_datetime(payload: Mapping[str, Any], *keys: str) -> datetime | None:
    for key in keys:
        value = _datetime_from_value(payload.get(key))
        if value:
            return value
    return None


def _datetime_from_value(value: Any) -> datetime | None:
    if isinstance(value, datetime):
        return _to_utc_naive(value)
    if not isinstance(value, str) or not value.strip():
        return None
    raw_value = value.strip()
    try:
        parsed = datetime.fromisoformat(raw_value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValidationError(f"Invalid datetime value: {raw_value}") from exc
    return _to_utc_naive(parsed)


def _to_utc_naive(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value
    return value.astimezone(UTC).replace(tzinfo=None)


def _text(value: Any) -> str | None:
    return normalize_optional_text(value)


def _bool(value: Any) -> bool:
    return bool(_bool_or_none(value))


def _bool_or_none(value: Any) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "1", "yes", "si", "sí", "y"}:
            return True
        if normalized in {"false", "0", "no", "n"}:
            return False
    return None
