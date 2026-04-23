import hashlib
import json
from collections.abc import Mapping
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from mappers.common import normalize_optional_text
from models.status_event import (
    StatusContext,
    StatusConversation,
    StatusCustomer,
    StatusMessage,
    StatusOperator,
    StatusSnapshot,
    StatusWebhookEvent,
)
from models.webhook_event import WebhookEnvelope
from utils.exceptions import ValidationError

STATUS_EVENT_TYPE = "message_status_snapshot"

_DYNAMIC_CONTEXT_ALLOWLIST = {
    "AP_Actividad",
    "ActividadCode",
    "ActividadName",
    "BusquedaActividad",
    "DeathAmount",
    "IssueResuelto",
    "PreguntarAccionCompleta",
    "RespuestaAccionCompleta",
    "typeDate",
    "AP_Desde",
    "AP_Hasta",
    "AP_validity_start",
    "AP_validity_end",
    "AP_Price",
    "AP_Price_Total",
    "AP_QuoteId",
    "AP_CoverageId",
    "AP_Quote_Descrption",
}


class StatusPayloadMapper:
    def to_status_event(self, envelope: WebhookEnvelope) -> StatusWebhookEvent:
        payload = envelope.payload
        last_message = _last_message(payload)
        received_at = _to_utc_naive(envelope.received_at) or datetime.now(UTC).replace(tzinfo=None)

        status_current = _first_text(payload, "STATUS", "status")
        if not status_current:
            raise ValidationError("Status payload is missing STATUS")

        customer_external_id = _first_text(payload, "_id_", "customerId") or _text(
            last_message.get("customerId")
        )
        if not customer_external_id:
            raise ValidationError("Status payload is missing customer identifier")

        snapshot_at = (
            _first_datetime(payload, "STATUS_CHANGE_TIME", "statusChangeTime", "status_change_time")
            or _datetime_from_value(last_message.get("date"))
            or _first_datetime(payload, "LAST_MESSAGE_CREATION_TIME", "lastMessageCreationTime")
            or received_at
        )

        conversation_external_id = (
            _text(last_message.get("sessionId"))
            or _first_text(payload, "conversationId", "conversation_id", "sessionId", "session_id")
            or customer_external_id
        )

        channel = (
            _text(last_message.get("chatPlatform"))
            or _first_text(payload, "CHAT_PLATFORM_ID", "chatPlatform", "channel")
            or "unknown"
        )
        contact_external_id = _first_text(payload, "PLATFORM_CONTACT_ID", "contactId") or _text(
            last_message.get("contactId")
        )
        business_channel_id = _first_text(payload, "chatChannelId", "businessChannelId")
        business_channel_address = _first_text(
            payload,
            "WHATSAPP_NUMBER",
            "businessChannelAddress",
        )
        queue_name = _text(last_message.get("queue")) or _first_text(payload, "QUEUE", "queue")
        sender_type = _sender_type(last_message)
        message_at = _datetime_from_value(last_message.get("date"))
        operator = _operator(envelope.provider_name, last_message)
        message = _message(
            envelope.provider_name,
            last_message,
            status_current,
            snapshot_at,
            queue_name,
            sender_type,
        )
        context = _context(envelope.provider_name, payload, snapshot_at)

        customer = StatusCustomer(
            provider_name=envelope.provider_name,
            customer_external_id=customer_external_id,
            contact_external_id=contact_external_id,
            channel=channel,
            business_channel_id=business_channel_id,
            business_channel_address=business_channel_address,
            customer_first_name=_first_text(payload, "FIRST_NAME", "firstName", "first_name"),
            customer_last_name=_first_text(payload, "LAST_NAME", "lastName", "last_name"),
            customer_country_code=_first_text(payload, "country", "COUNTRY"),
            customer_locale=_first_text(payload, "locale", "LOCALE"),
            customer_gender=_first_text(payload, "gender", "GENDER"),
            customer_created_at=_first_datetime(payload, "CREATION_TIME", "creationTime"),
        )

        conversation = StatusConversation(
            provider_name=envelope.provider_name,
            conversation_external_id=conversation_external_id,
            channel=channel,
            business_channel_id=business_channel_id,
            business_channel_address=business_channel_address,
            conversation_started_at=_datetime_from_value(last_message.get("sessionCreationTime"))
            or customer.customer_created_at,
            first_user_message_at=message_at if sender_type == "customer" else None,
            first_bot_response_at=message_at if sender_type == "bot" else None,
            first_human_response_at=message_at if sender_type == "operator" else None,
            last_message_at=message_at,
            last_message_sender_type=sender_type,
            current_queue_name=queue_name,
            is_bot_muted=_bool(payload.get("BOT_MUTED")),
            pending_message_count=_int(payload.get("PENDING_MSGS"), default=0),
            last_action_author_external_id=_first_text(payload, "Last action author", "lastActionAuthor"),
            status_current=status_current,
            topic=context.topic,
            subtopic=context.subtopic,
            product=context.product,
            resolved_flag=_bool_or_none(payload.get("IssueResuelto")),
        )

        snapshot = StatusSnapshot(
            provider_name=envelope.provider_name,
            snapshot_at=snapshot_at,
            status_current=status_current,
            is_bot_muted=conversation.is_bot_muted,
            pending_message_count=conversation.pending_message_count,
            last_seen_at=_first_datetime(payload, "LAST_SEEN", "lastSeen"),
            last_user_message_received_at=_first_datetime(
                payload,
                "USER_LAST_MSG_RECEIVED",
                "userLastMessageReceived",
            ),
            last_user_message_read_at=_first_datetime(
                payload,
                "USER_LAST_MSG_READ",
                "userLastMessageRead",
            ),
            last_action_author_external_id=conversation.last_action_author_external_id,
            queue_name=queue_name,
            executed_intents_json=_json_list(payload.get("EXECUTED_INTENTS")),
            last_message_external_id=message.message_external_id if message else None,
            last_message_at=message_at,
            last_message_sender_type=sender_type,
            last_message_sender_name=_sender_name(last_message, sender_type),
            last_message_text=_text(last_message.get("message")),
            operator_external_id=operator.operator_external_id if operator else None,
            operator_name=operator.operator_name if operator else None,
            operator_email=operator.operator_email if operator else None,
        )

        external_event_key = build_status_external_event_key(
            provider_name=envelope.provider_name,
            source_endpoint=envelope.source_endpoint,
            conversation_external_id=conversation_external_id,
            message_external_id=message.message_external_id if message else None,
            status=status_current,
            status_change_time=snapshot_at,
            customer_external_id=customer_external_id,
        )

        return StatusWebhookEvent(
            provider_name=envelope.provider_name,
            source_endpoint=envelope.source_endpoint,
            event_type=STATUS_EVENT_TYPE,
            external_event_key=external_event_key,
            conversation_external_id=conversation_external_id,
            customer_external_id=customer_external_id,
            received_at=received_at,
            request_id=envelope.request_id,
            headers=envelope.headers,
            raw_payload=payload,
            customer=customer,
            conversation=conversation,
            snapshot=snapshot,
            context=context,
            message=message,
            operator=operator,
            trace_context={
                "status": status_current,
                "conversation_external_id": conversation_external_id,
                "customer_external_id": customer_external_id,
                "message_external_id": message.message_external_id if message else None,
            },
        )


def build_status_external_event_key(
    *,
    provider_name: str,
    source_endpoint: str,
    conversation_external_id: str,
    message_external_id: str | None,
    status: str,
    status_change_time: datetime,
    customer_external_id: str,
) -> str:
    identity = {
        "provider_name": provider_name,
        "source_endpoint": source_endpoint,
        "conversation_external_id": conversation_external_id,
        "message_external_id": message_external_id or f"no-message:{customer_external_id}",
        "status": status,
        "status_change_time": status_change_time.isoformat(timespec="milliseconds"),
    }
    digest = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return f"status:v1:{digest}"


def _last_message(payload: Mapping[str, Any]) -> Mapping[str, Any]:
    raw_last_message = payload.get("LAST_MESSAGE")
    if raw_last_message is None:
        return {}
    if not isinstance(raw_last_message, Mapping):
        raise ValidationError("Status payload LAST_MESSAGE must be an object")
    return raw_last_message


def _operator(provider_name: str, last_message: Mapping[str, Any]) -> StatusOperator | None:
    operator_external_id = (
        _text(last_message.get("operatorId"))
        or _text(last_message.get("operatorEmail"))
        or (_text(last_message.get("operatorName")) if _sender_type(last_message) == "operator" else None)
    )
    if not operator_external_id:
        return None

    return StatusOperator(
        provider_name=provider_name,
        operator_external_id=operator_external_id,
        operator_name=_text(last_message.get("operatorName")) or _text(last_message.get("fromName")),
        operator_email=_text(last_message.get("operatorEmail")),
    )


def _message(
    provider_name: str,
    last_message: Mapping[str, Any],
    status_current: str,
    snapshot_at: datetime,
    queue_name: str | None,
    sender_type: str | None,
) -> StatusMessage | None:
    message_external_id = _text(last_message.get("_id_")) or _text(last_message.get("messageId"))
    if not last_message or not message_external_id:
        return None

    message_at = _datetime_from_value(last_message.get("date")) or snapshot_at
    attachment_url = _attachment_url(last_message)
    has_attachment = _bool(last_message.get("hasAttachment")) or bool(attachment_url)

    return StatusMessage(
        provider_name=provider_name,
        message_external_id=message_external_id,
        message_at=message_at,
        direction="inbound" if sender_type == "customer" else "outbound",
        sender_type=sender_type or "unknown",
        sender_name=_sender_name(last_message, sender_type),
        message_text=_text(last_message.get("message")),
        is_button=_bool(last_message.get("isButton")),
        button_label=_text(last_message.get("buttonName")),
        is_customer_message=(
            _bool_or_none(last_message.get("fromCustomer"))
            if "fromCustomer" in last_message
            else sender_type == "customer"
        )
        or False,
        has_attachment=has_attachment,
        attachment_type=_attachment_type(last_message, attachment_url),
        attachment_url=attachment_url,
        intent_name=None,
        queue_name=queue_name,
        delivery_status=status_current,
        delivery_status_at=snapshot_at,
        client_payload={
            "last_message": {
                key: value
                for key, value in last_message.items()
                if key
                in {
                    "_id_",
                    "date",
                    "from",
                    "fromCustomer",
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
                    "chatPlatform",
                    "operatorId",
                    "operatorName",
                    "operatorEmail",
                    "queue",
                    "sessionId",
                    "customerId",
                    "contactId",
                }
            }
        },
    )


def _context(
    provider_name: str,
    payload: Mapping[str, Any],
    snapshot_at: datetime,
) -> StatusContext:
    return StatusContext(
        provider_name=provider_name,
        snapshot_at=snapshot_at,
        product=_first_text(payload, "product", "PRODUCT", "Producto"),
        topic=_first_text(payload, "topic", "TOPIC", "Tema"),
        subtopic=_first_text(payload, "subtopic", "SUBTOPIC", "Subtema"),
        quote_external_id=_first_text(payload, "AP_QuoteId", "quoteId", "quote_external_id"),
        coverage_external_id=_first_text(payload, "AP_CoverageId", "coverageId", "coverage_external_id"),
        quoted_total_amount=_decimal(payload.get("AP_Price_Total")) or _decimal(payload.get("AP_Price")),
        quote_description=_first_text(payload, "AP_Quote_Descrption", "quoteDescription"),
        activity_name=_first_text(payload, "ActividadName", "AP_Actividad", "activityName"),
        completion_message_text=_first_text(
            payload,
            "RespuestaAccionCompleta",
            "completionMessageText",
        ),
        context_json=_dynamic_context(payload),
    )


def _dynamic_context(payload: Mapping[str, Any]) -> dict[str, Any] | None:
    context = {
        key: value
        for key, value in payload.items()
        if isinstance(key, str)
        and key in _DYNAMIC_CONTEXT_ALLOWLIST
        and value is not None
        and normalize_optional_text(value) is not None
    }
    return context or None


def _sender_type(last_message: Mapping[str, Any]) -> str | None:
    sender = (_text(last_message.get("from")) or "").lower()
    if sender in {"user", "customer"}:
        return "customer"
    if sender in {"bot", "operator"}:
        return sender
    if _bool_or_none(last_message.get("fromCustomer")) is True:
        return "customer"
    if _text(last_message.get("operatorId")) or _text(last_message.get("operatorEmail")):
        return "operator"
    return sender or None


def _sender_name(last_message: Mapping[str, Any], sender_type: str | None) -> str | None:
    if sender_type == "operator":
        return _text(last_message.get("operatorName")) or _text(last_message.get("fromName"))
    return _text(last_message.get("fromName"))


def _attachment_url(last_message: Mapping[str, Any]) -> str | None:
    return (
        _text(last_message.get("image"))
        or _text(last_message.get("audio"))
        or _text(last_message.get("file"))
        or _text(last_message.get("attachmentUrl"))
        or _text(last_message.get("fileUrl"))
        or _text(last_message.get("mediaUrl"))
    )


def _attachment_type(last_message: Mapping[str, Any], attachment_url: str | None) -> str | None:
    if not attachment_url:
        return None
    if _text(last_message.get("image")):
        return "image"
    if _text(last_message.get("audio")):
        return "audio"
    if _text(last_message.get("file")) or _text(last_message.get("fileUrl")):
        return "file"
    return _first_text(last_message, "attachmentType", "mediaType") or "attachment"


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


def _int(value: Any, *, default: int) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _decimal(value: Any) -> Decimal | None:
    if value is None or value == "":
        return None
    try:
        return Decimal(str(value).replace(",", "."))
    except (InvalidOperation, ValueError):
        return None


def _json_list(value: Any) -> list[Any] | None:
    if value is None:
        return None
    if isinstance(value, list):
        return value
    return [value]
