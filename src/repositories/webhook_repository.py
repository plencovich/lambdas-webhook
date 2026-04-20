import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from models.incoming_event import IncomingWebhookEvent
from models.status_event import StatusWebhookEvent
from models.webhook_event import WebhookEnvelope
from repositories.base import BaseRepository
from utils.exceptions import DatabaseQueryError


@dataclass(frozen=True, slots=True)
class RawEventWriteResult:
    raw_event_id: int | None
    duplicate: bool
    processing_status: str | None = None


class WebhookRepository(BaseRepository):
    def save_raw_event(self, envelope: WebhookEnvelope) -> None:
        external_event_key = envelope.idempotency_key or _hash_external_event_key(envelope)
        self._insert_raw_event(
            provider_name=envelope.provider_name,
            source_endpoint=envelope.source_endpoint,
            event_type=envelope.event_type,
            external_event_key=external_event_key,
            conversation_external_id=_payload_text(
                envelope.payload,
                "conversationId",
                "conversation_id",
                "sessionId",
            ),
            customer_external_id=_payload_text(envelope.payload, "_id_", "customerId"),
            received_at=envelope.received_at,
            raw_payload=envelope.payload,
            processing_status="processed",
            processed_at=envelope.received_at,
        )

    def register_status_raw_event(self, event: StatusWebhookEvent) -> RawEventWriteResult:
        return self._insert_raw_event(
            provider_name=event.provider_name,
            source_endpoint=event.source_endpoint,
            event_type=event.event_type,
            external_event_key=event.external_event_key,
            conversation_external_id=event.conversation_external_id,
            customer_external_id=event.customer_external_id,
            received_at=event.received_at,
            raw_payload=event.raw_payload,
            processing_status="processing",
            processed_at=None,
        )

    def register_incoming_raw_event(self, event: IncomingWebhookEvent) -> RawEventWriteResult:
        return self._insert_raw_event(
            provider_name=event.provider_name,
            source_endpoint=event.source_endpoint,
            event_type=event.event_type,
            external_event_key=event.external_event_key,
            conversation_external_id=event.conversation_external_id,
            customer_external_id=event.customer_external_id,
            received_at=event.received_at,
            raw_payload=event.raw_payload,
            processing_status="processing",
            processed_at=None,
        )

    def save_status_event(self, event: StatusWebhookEvent, raw_event_id: int) -> dict[str, int | None]:
        try:
            with self.transaction() as connection:
                with connection.cursor() as cursor:
                    customer_id = self._upsert_customer(cursor, event)
                    operator_id = self._upsert_operator(cursor, event)
                    conversation_id = self._upsert_conversation(cursor, event, customer_id)
                    message_id = self._upsert_message(
                        cursor,
                        event,
                        conversation_id,
                        customer_id,
                        operator_id,
                    )
                    snapshot_id = self._insert_snapshot(cursor, event, conversation_id, customer_id)
                    context_id = self._insert_context(cursor, event, conversation_id, customer_id)
                    self._mark_raw_processed(cursor, raw_event_id)

            return {
                "customer_id": customer_id,
                "operator_id": operator_id,
                "conversation_id": conversation_id,
                "message_id": message_id,
                "snapshot_id": snapshot_id,
                "context_id": context_id,
            }
        except DatabaseQueryError:
            raise
        except Exception as exc:
            raise DatabaseQueryError("Status event persistence failed") from exc

    def save_incoming_event(
        self,
        event: IncomingWebhookEvent,
        raw_event_id: int,
    ) -> dict[str, int | None]:
        try:
            with self.transaction() as connection:
                with connection.cursor() as cursor:
                    customer_id = self._upsert_customer(cursor, event)
                    conversation_id = self._upsert_incoming_conversation(cursor, event, customer_id)
                    message_id = self._upsert_message(
                        cursor,
                        event,
                        conversation_id,
                        customer_id,
                        None,
                    )
                    self._mark_raw_processed(cursor, raw_event_id)

            return {
                "customer_id": customer_id,
                "operator_id": None,
                "conversation_id": conversation_id,
                "message_id": message_id,
            }
        except DatabaseQueryError:
            raise
        except Exception as exc:
            raise DatabaseQueryError("Incoming event persistence failed") from exc

    def mark_raw_failed(self, raw_event_id: int, error: str) -> None:
        self.execute(
            """
            UPDATE webhook_events_raw
            SET processing_status = 'failed',
                processed_at = %s,
                processing_error = %s
            WHERE id = %s
            """,
            (_utc_now(), error[:4000], raw_event_id),
        )

    def _insert_raw_event(
        self,
        *,
        provider_name: str,
        source_endpoint: str,
        event_type: str,
        external_event_key: str,
        conversation_external_id: str | None,
        customer_external_id: str | None,
        received_at: datetime,
        raw_payload: Any,
        processing_status: str,
        processed_at: datetime | None,
    ) -> RawEventWriteResult:
        connection = self._connection_factory()
        try:
            with connection.cursor() as cursor:
                rowcount = cursor.execute(
                    """
                    INSERT IGNORE INTO webhook_events_raw (
                        provider_name,
                        source_endpoint,
                        event_type,
                        external_event_key,
                        conversation_external_id,
                        customer_external_id,
                        received_at,
                        processed_at,
                        processing_status,
                        raw_payload_json
                    )
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        provider_name,
                        source_endpoint,
                        event_type,
                        external_event_key,
                        conversation_external_id,
                        customer_external_id,
                        _mysql_datetime(received_at),
                        _mysql_datetime(processed_at),
                        processing_status,
                        _json_dumps(raw_payload),
                    ),
                )
                if rowcount == 1:
                    raw_event_id = int(cursor.lastrowid or 0)
                    connection.commit()
                    return RawEventWriteResult(raw_event_id=raw_event_id, duplicate=False)

                cursor.execute(
                    """
                    SELECT id, processing_status
                    FROM webhook_events_raw
                    WHERE provider_name = %s
                      AND external_event_key = %s
                    LIMIT 1
                    """,
                    (provider_name, external_event_key),
                )
                existing = cursor.fetchone() or {}
                connection.commit()
                return RawEventWriteResult(
                    raw_event_id=existing.get("id"),
                    duplicate=True,
                    processing_status=existing.get("processing_status"),
                )
        except Exception as exc:
            connection.rollback()
            raise DatabaseQueryError("Raw webhook event insert failed") from exc

    def _upsert_customer(self, cursor: Any, event: StatusWebhookEvent | IncomingWebhookEvent) -> int:
        customer = event.customer
        cursor.execute(
            """
            INSERT INTO customers (
                provider_name,
                customer_external_id,
                contact_external_id,
                channel,
                business_channel_id,
                business_channel_address,
                customer_first_name,
                customer_last_name,
                customer_country_code,
                customer_locale,
                customer_gender,
                customer_created_at
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE
                id = LAST_INSERT_ID(id),
                contact_external_id = COALESCE(VALUES(contact_external_id), contact_external_id),
                channel = VALUES(channel),
                business_channel_id = COALESCE(VALUES(business_channel_id), business_channel_id),
                business_channel_address = COALESCE(VALUES(business_channel_address), business_channel_address),
                customer_first_name = COALESCE(VALUES(customer_first_name), customer_first_name),
                customer_last_name = COALESCE(VALUES(customer_last_name), customer_last_name),
                customer_country_code = COALESCE(VALUES(customer_country_code), customer_country_code),
                customer_locale = COALESCE(VALUES(customer_locale), customer_locale),
                customer_gender = COALESCE(VALUES(customer_gender), customer_gender),
                customer_created_at = CASE
                    WHEN customer_created_at IS NULL THEN VALUES(customer_created_at)
                    WHEN VALUES(customer_created_at) IS NULL THEN customer_created_at
                    ELSE LEAST(customer_created_at, VALUES(customer_created_at))
                END
            """,
            (
                customer.provider_name,
                customer.customer_external_id,
                customer.contact_external_id,
                customer.channel,
                customer.business_channel_id,
                customer.business_channel_address,
                customer.customer_first_name,
                customer.customer_last_name,
                customer.customer_country_code,
                customer.customer_locale,
                customer.customer_gender,
                _mysql_datetime(customer.customer_created_at),
            ),
        )
        return int(cursor.lastrowid)

    def _upsert_operator(self, cursor: Any, event: StatusWebhookEvent) -> int | None:
        operator = event.operator
        if operator is None:
            return None

        cursor.execute(
            """
            INSERT INTO operators (
                provider_name,
                operator_external_id,
                operator_name,
                operator_email,
                operator_role
            )
            VALUES (%s, %s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE
                id = LAST_INSERT_ID(id),
                operator_name = COALESCE(VALUES(operator_name), operator_name),
                operator_email = COALESCE(VALUES(operator_email), operator_email),
                operator_role = COALESCE(VALUES(operator_role), operator_role)
            """,
            (
                operator.provider_name,
                operator.operator_external_id,
                operator.operator_name,
                operator.operator_email,
                operator.operator_role,
            ),
        )
        return int(cursor.lastrowid)

    def _upsert_conversation(
        self,
        cursor: Any,
        event: StatusWebhookEvent,
        customer_id: int,
    ) -> int:
        conversation = event.conversation
        cursor.execute(
            """
            INSERT INTO conversations (
                provider_name,
                conversation_external_id,
                customer_id,
                channel,
                business_channel_id,
                business_channel_address,
                conversation_started_at,
                first_user_message_at,
                first_bot_response_at,
                first_human_response_at,
                last_message_at,
                last_message_sender_type,
                current_queue_name,
                is_bot_muted,
                pending_message_count,
                last_action_author_external_id,
                status_current,
                topic,
                subtopic,
                product,
                journey_stage,
                handoff_reason,
                resolved_flag,
                resolution_type,
                closed_by,
                closed_at
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE
                id = LAST_INSERT_ID(id),
                customer_id = VALUES(customer_id),
                channel = VALUES(channel),
                business_channel_id = COALESCE(VALUES(business_channel_id), business_channel_id),
                business_channel_address = COALESCE(VALUES(business_channel_address), business_channel_address),
                conversation_started_at = CASE
                    WHEN conversation_started_at IS NULL THEN VALUES(conversation_started_at)
                    WHEN VALUES(conversation_started_at) IS NULL THEN conversation_started_at
                    ELSE LEAST(conversation_started_at, VALUES(conversation_started_at))
                END,
                first_user_message_at = CASE
                    WHEN first_user_message_at IS NULL THEN VALUES(first_user_message_at)
                    WHEN VALUES(first_user_message_at) IS NULL THEN first_user_message_at
                    ELSE LEAST(first_user_message_at, VALUES(first_user_message_at))
                END,
                first_bot_response_at = CASE
                    WHEN first_bot_response_at IS NULL THEN VALUES(first_bot_response_at)
                    WHEN VALUES(first_bot_response_at) IS NULL THEN first_bot_response_at
                    ELSE LEAST(first_bot_response_at, VALUES(first_bot_response_at))
                END,
                first_human_response_at = CASE
                    WHEN first_human_response_at IS NULL THEN VALUES(first_human_response_at)
                    WHEN VALUES(first_human_response_at) IS NULL THEN first_human_response_at
                    ELSE LEAST(first_human_response_at, VALUES(first_human_response_at))
                END,
                last_message_at = CASE
                    WHEN VALUES(last_message_at) IS NULL THEN last_message_at
                    WHEN last_message_at IS NULL THEN VALUES(last_message_at)
                    ELSE GREATEST(last_message_at, VALUES(last_message_at))
                END,
                last_message_sender_type = COALESCE(VALUES(last_message_sender_type), last_message_sender_type),
                current_queue_name = COALESCE(VALUES(current_queue_name), current_queue_name),
                is_bot_muted = VALUES(is_bot_muted),
                pending_message_count = VALUES(pending_message_count),
                last_action_author_external_id = COALESCE(
                    VALUES(last_action_author_external_id),
                    last_action_author_external_id
                ),
                status_current = COALESCE(VALUES(status_current), status_current),
                topic = COALESCE(VALUES(topic), topic),
                subtopic = COALESCE(VALUES(subtopic), subtopic),
                product = COALESCE(VALUES(product), product),
                journey_stage = COALESCE(VALUES(journey_stage), journey_stage),
                handoff_reason = COALESCE(VALUES(handoff_reason), handoff_reason),
                resolved_flag = COALESCE(VALUES(resolved_flag), resolved_flag),
                resolution_type = COALESCE(VALUES(resolution_type), resolution_type),
                closed_by = COALESCE(VALUES(closed_by), closed_by),
                closed_at = COALESCE(VALUES(closed_at), closed_at)
            """,
            (
                conversation.provider_name,
                conversation.conversation_external_id,
                customer_id,
                conversation.channel,
                conversation.business_channel_id,
                conversation.business_channel_address,
                _mysql_datetime(conversation.conversation_started_at),
                _mysql_datetime(conversation.first_user_message_at),
                _mysql_datetime(conversation.first_bot_response_at),
                _mysql_datetime(conversation.first_human_response_at),
                _mysql_datetime(conversation.last_message_at),
                conversation.last_message_sender_type,
                conversation.current_queue_name,
                _tinyint(conversation.is_bot_muted),
                conversation.pending_message_count,
                conversation.last_action_author_external_id,
                conversation.status_current,
                conversation.topic,
                conversation.subtopic,
                conversation.product,
                conversation.journey_stage,
                conversation.handoff_reason,
                _tinyint_or_none(conversation.resolved_flag),
                conversation.resolution_type,
                conversation.closed_by,
                _mysql_datetime(conversation.closed_at),
            ),
        )
        return int(cursor.lastrowid)

    def _upsert_incoming_conversation(
        self,
        cursor: Any,
        event: IncomingWebhookEvent,
        customer_id: int,
    ) -> int:
        conversation = event.conversation
        cursor.execute(
            """
            INSERT INTO conversations (
                provider_name,
                conversation_external_id,
                customer_id,
                channel,
                business_channel_id,
                business_channel_address,
                conversation_started_at,
                first_user_message_at,
                last_message_at,
                last_message_sender_type,
                current_queue_name
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE
                id = LAST_INSERT_ID(id),
                customer_id = VALUES(customer_id),
                channel = VALUES(channel),
                business_channel_id = COALESCE(VALUES(business_channel_id), business_channel_id),
                business_channel_address = COALESCE(VALUES(business_channel_address), business_channel_address),
                conversation_started_at = CASE
                    WHEN conversation_started_at IS NULL THEN VALUES(conversation_started_at)
                    WHEN VALUES(conversation_started_at) IS NULL THEN conversation_started_at
                    ELSE LEAST(conversation_started_at, VALUES(conversation_started_at))
                END,
                first_user_message_at = CASE
                    WHEN first_user_message_at IS NULL THEN VALUES(first_user_message_at)
                    WHEN VALUES(first_user_message_at) IS NULL THEN first_user_message_at
                    ELSE LEAST(first_user_message_at, VALUES(first_user_message_at))
                END,
                last_message_sender_type = CASE
                    WHEN VALUES(last_message_at) IS NULL THEN last_message_sender_type
                    WHEN last_message_at IS NULL OR VALUES(last_message_at) >= last_message_at THEN
                        COALESCE(VALUES(last_message_sender_type), last_message_sender_type)
                    ELSE last_message_sender_type
                END,
                current_queue_name = CASE
                    WHEN VALUES(last_message_at) IS NULL THEN COALESCE(VALUES(current_queue_name), current_queue_name)
                    WHEN last_message_at IS NULL OR VALUES(last_message_at) >= last_message_at THEN
                        COALESCE(VALUES(current_queue_name), current_queue_name)
                    ELSE current_queue_name
                END,
                last_message_at = CASE
                    WHEN VALUES(last_message_at) IS NULL THEN last_message_at
                    WHEN last_message_at IS NULL THEN VALUES(last_message_at)
                    ELSE GREATEST(last_message_at, VALUES(last_message_at))
                END
            """,
            (
                conversation.provider_name,
                conversation.conversation_external_id,
                customer_id,
                conversation.channel,
                conversation.business_channel_id,
                conversation.business_channel_address,
                _mysql_datetime(conversation.conversation_started_at),
                _mysql_datetime(conversation.first_user_message_at),
                _mysql_datetime(conversation.last_message_at),
                conversation.last_message_sender_type,
                conversation.current_queue_name,
            ),
        )
        return int(cursor.lastrowid)

    def _upsert_message(
        self,
        cursor: Any,
        event: StatusWebhookEvent | IncomingWebhookEvent,
        conversation_id: int,
        customer_id: int,
        operator_id: int | None,
    ) -> int | None:
        message = event.message
        if message is None:
            return None

        cursor.execute(
            """
            INSERT INTO messages (
                provider_name,
                message_external_id,
                conversation_id,
                customer_id,
                operator_id,
                message_at,
                direction,
                sender_type,
                sender_name,
                message_text,
                is_button,
                button_label,
                is_customer_message,
                has_attachment,
                attachment_type,
                attachment_url,
                intent_name,
                queue_name,
                delivery_status,
                delivery_status_at,
                client_payload
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE
                id = LAST_INSERT_ID(id),
                conversation_id = VALUES(conversation_id),
                customer_id = VALUES(customer_id),
                operator_id = COALESCE(VALUES(operator_id), operator_id),
                message_at = LEAST(message_at, VALUES(message_at)),
                direction = VALUES(direction),
                sender_type = VALUES(sender_type),
                sender_name = COALESCE(VALUES(sender_name), sender_name),
                message_text = COALESCE(VALUES(message_text), message_text),
                is_button = GREATEST(is_button, VALUES(is_button)),
                button_label = COALESCE(VALUES(button_label), button_label),
                is_customer_message = GREATEST(is_customer_message, VALUES(is_customer_message)),
                has_attachment = GREATEST(has_attachment, VALUES(has_attachment)),
                attachment_type = COALESCE(VALUES(attachment_type), attachment_type),
                attachment_url = COALESCE(VALUES(attachment_url), attachment_url),
                intent_name = COALESCE(VALUES(intent_name), intent_name),
                queue_name = COALESCE(VALUES(queue_name), queue_name),
                delivery_status = COALESCE(VALUES(delivery_status), delivery_status),
                delivery_status_at = CASE
                    WHEN VALUES(delivery_status_at) IS NULL THEN delivery_status_at
                    WHEN delivery_status_at IS NULL THEN VALUES(delivery_status_at)
                    ELSE GREATEST(delivery_status_at, VALUES(delivery_status_at))
                END,
                client_payload = COALESCE(VALUES(client_payload), client_payload)
            """,
            (
                message.provider_name,
                message.message_external_id,
                conversation_id,
                customer_id,
                operator_id,
                _mysql_datetime(message.message_at),
                message.direction,
                message.sender_type,
                message.sender_name,
                message.message_text,
                _tinyint(message.is_button),
                message.button_label,
                _tinyint(message.is_customer_message),
                _tinyint(message.has_attachment),
                message.attachment_type,
                message.attachment_url,
                message.intent_name,
                message.queue_name,
                message.delivery_status,
                _mysql_datetime(message.delivery_status_at),
                _json_dumps(message.client_payload),
            ),
        )
        return int(cursor.lastrowid)

    def _insert_snapshot(
        self,
        cursor: Any,
        event: StatusWebhookEvent,
        conversation_id: int,
        customer_id: int,
    ) -> int:
        snapshot = event.snapshot
        cursor.execute(
            """
            INSERT INTO conversation_snapshots (
                provider_name,
                conversation_id,
                customer_id,
                snapshot_at,
                status_current,
                is_bot_muted,
                pending_message_count,
                last_seen_at,
                last_user_message_received_at,
                last_user_message_read_at,
                last_action_author_external_id,
                queue_name,
                executed_intents_json,
                last_message_external_id,
                last_message_at,
                last_message_sender_type,
                last_message_sender_name,
                last_message_text,
                operator_external_id,
                operator_name,
                operator_email
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (
                snapshot.provider_name,
                conversation_id,
                customer_id,
                _mysql_datetime(snapshot.snapshot_at),
                snapshot.status_current,
                _tinyint(snapshot.is_bot_muted),
                snapshot.pending_message_count,
                _mysql_datetime(snapshot.last_seen_at),
                _mysql_datetime(snapshot.last_user_message_received_at),
                _mysql_datetime(snapshot.last_user_message_read_at),
                snapshot.last_action_author_external_id,
                snapshot.queue_name,
                _json_dumps(snapshot.executed_intents_json),
                snapshot.last_message_external_id,
                _mysql_datetime(snapshot.last_message_at),
                snapshot.last_message_sender_type,
                snapshot.last_message_sender_name,
                snapshot.last_message_text,
                snapshot.operator_external_id,
                snapshot.operator_name,
                snapshot.operator_email,
            ),
        )
        return int(cursor.lastrowid)

    def _insert_context(
        self,
        cursor: Any,
        event: StatusWebhookEvent,
        conversation_id: int,
        customer_id: int,
    ) -> int:
        context = event.context
        cursor.execute(
            """
            INSERT INTO conversation_contexts (
                provider_name,
                conversation_id,
                customer_id,
                snapshot_at,
                product,
                topic,
                subtopic,
                quote_external_id,
                coverage_external_id,
                quoted_total_amount,
                quote_description,
                activity_name,
                completion_message_text,
                context_json
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (
                context.provider_name,
                conversation_id,
                customer_id,
                _mysql_datetime(context.snapshot_at),
                context.product,
                context.topic,
                context.subtopic,
                context.quote_external_id,
                context.coverage_external_id,
                context.quoted_total_amount,
                context.quote_description,
                context.activity_name,
                context.completion_message_text,
                _json_dumps(context.context_json),
            ),
        )
        return int(cursor.lastrowid)

    def _mark_raw_processed(self, cursor: Any, raw_event_id: int) -> None:
        cursor.execute(
            """
            UPDATE webhook_events_raw
            SET processing_status = 'processed',
                processed_at = %s,
                processing_error = NULL
            WHERE id = %s
            """,
            (_utc_now(), raw_event_id),
        )


def _hash_external_event_key(envelope: WebhookEnvelope) -> str:
    digest = hashlib.sha256(
        json.dumps(
            {
                "provider_name": envelope.provider_name,
                "source_endpoint": envelope.source_endpoint,
                "payload": envelope.payload,
            },
            sort_keys=True,
            default=str,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return f"{envelope.source_endpoint}:v1:{digest}"


def _payload_text(payload: Any, *keys: str) -> str | None:
    if not isinstance(payload, dict):
        return None
    for key in keys:
        value = payload.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return None


def _json_dumps(value: Any) -> str | None:
    if value is None:
        return None
    return json.dumps(value, ensure_ascii=False, default=str, separators=(",", ":"))


def _mysql_datetime(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value
    return value.astimezone(UTC).replace(tzinfo=None)


def _utc_now() -> datetime:
    return datetime.now(UTC).replace(tzinfo=None)


def _tinyint(value: bool) -> int:
    return 1 if value else 0


def _tinyint_or_none(value: bool | None) -> int | None:
    if value is None:
        return None
    return _tinyint(value)
