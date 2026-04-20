from collections.abc import Mapping
from typing import Any

from mappers.incoming_mapper import IncomingPayloadMapper
from mappers.outgoing_mapper import OutgoingPayloadMapper
from mappers.status_mapper import StatusPayloadMapper
from mappers.webhook_mapper import WebhookMapper
from models.incoming_event import IncomingWebhookEvent
from models.outgoing_event import OutgoingWebhookEvent
from models.webhook_event import WebhookEnvelope
from repositories.webhook_repository import WebhookRepository
from utils.exceptions import DatabaseError
from utils.log import get_logger
from utils.payload import parse_json_body

logger = get_logger(__name__)
_RETRYABLE_DUPLICATE_RAW_STATUSES = {"failed"}


class WebhookIngestionService:
    def __init__(
        self,
        mapper: WebhookMapper | None = None,
        status_mapper: StatusPayloadMapper | None = None,
        incoming_mapper: IncomingPayloadMapper | None = None,
        outgoing_mapper: OutgoingPayloadMapper | None = None,
        repository: WebhookRepository | None = None,
    ) -> None:
        self._mapper = mapper or WebhookMapper()
        self._status_mapper = status_mapper or StatusPayloadMapper()
        self._incoming_mapper = incoming_mapper or IncomingPayloadMapper()
        self._outgoing_mapper = outgoing_mapper or OutgoingPayloadMapper()
        self._repository = repository or WebhookRepository()

    def process(
        self,
        source_endpoint: str,
        event: Mapping[str, Any],
        context: Any | None = None,
    ) -> dict[str, Any]:
        logger.info(
            "Webhook request received",
            extra={"source_endpoint": source_endpoint},
        )
        payload = parse_json_body(event)
        logger.info(
            "Webhook payload parsed",
            extra={
                "source_endpoint": source_endpoint,
                "payload_field_count": len(payload),
            },
        )
        envelope = self._mapper.to_envelope(source_endpoint, event, payload, context)

        if source_endpoint == "status":
            return self._process_status(envelope)
        if source_endpoint == "incoming":
            return self._process_incoming(envelope)
        if source_endpoint == "outgoing":
            return self._process_outgoing(envelope)

        self._repository.save_raw_event(envelope)

        logger.info(
            "Webhook accepted",
            extra={
                "source_endpoint": envelope.source_endpoint,
                "event_type": envelope.event_type,
                "request_id": envelope.request_id,
            },
        )

        return {
            "status": "accepted",
            "provider": envelope.provider_name,
            "endpoint": envelope.source_endpoint,
            "event_type": envelope.event_type,
            "request_id": envelope.request_id,
            "idempotency_key": envelope.idempotency_key,
        }

    def _process_status(self, envelope: WebhookEnvelope) -> dict[str, Any]:
        status_event = self._status_mapper.to_status_event(envelope)

        logger.info(
            "Status webhook mapped",
            extra={
                "request_id": status_event.request_id,
                "source_endpoint": status_event.source_endpoint,
                "event_type": status_event.event_type,
                "external_event_key": status_event.external_event_key,
                **status_event.trace_context,
            },
        )

        raw_result = self._repository.register_status_raw_event(status_event)
        if raw_result.duplicate:
            if _should_retry_duplicate_raw(raw_result):
                logger.info(
                    "Retrying failed status webhook",
                    extra={
                        "request_id": status_event.request_id,
                        "source_endpoint": status_event.source_endpoint,
                        "external_event_key": status_event.external_event_key,
                        "raw_event_id": raw_result.raw_event_id,
                        "raw_processing_status": raw_result.processing_status,
                        **status_event.trace_context,
                    },
                )
            else:
                logger.info(
                    "Duplicate status webhook ignored",
                    extra={
                        "request_id": status_event.request_id,
                        "source_endpoint": status_event.source_endpoint,
                        "external_event_key": status_event.external_event_key,
                        "raw_event_id": raw_result.raw_event_id,
                        "raw_processing_status": raw_result.processing_status,
                        **status_event.trace_context,
                    },
                )
                return {
                    "status": "duplicate_ignored",
                    "provider": status_event.provider_name,
                    "endpoint": status_event.source_endpoint,
                    "event_type": status_event.event_type,
                    "request_id": status_event.request_id,
                    "external_event_key": status_event.external_event_key,
                    "raw_event_id": raw_result.raw_event_id,
                }

        if raw_result.raw_event_id is None:
            raise DatabaseError("Raw status webhook event was not persisted")

        try:
            entity_ids = self._repository.save_status_event(status_event, raw_result.raw_event_id)
        except Exception as exc:
            try:
                self._repository.mark_raw_failed(raw_result.raw_event_id, str(exc))
            except Exception as mark_error:
                logger.error(
                    "Could not mark raw status webhook as failed",
                    extra={
                        "request_id": status_event.request_id,
                        "external_event_key": status_event.external_event_key,
                        "raw_event_id": raw_result.raw_event_id,
                        "mark_error_type": mark_error.__class__.__name__,
                    },
                )
            raise

        logger.info(
            "Status webhook processed",
            extra={
                "request_id": status_event.request_id,
                "source_endpoint": status_event.source_endpoint,
                "external_event_key": status_event.external_event_key,
                "raw_event_id": raw_result.raw_event_id,
                **status_event.trace_context,
                **entity_ids,
            },
        )

        return {
            "status": "processed",
            "provider": status_event.provider_name,
            "endpoint": status_event.source_endpoint,
            "event_type": status_event.event_type,
            "request_id": status_event.request_id,
            "external_event_key": status_event.external_event_key,
            "raw_event_id": raw_result.raw_event_id,
            "entities": entity_ids,
        }

    def _process_incoming(self, envelope: WebhookEnvelope) -> dict[str, Any]:
        incoming_event = self._incoming_mapper.to_incoming_event(envelope)

        logger.info(
            "Incoming webhook mapped",
            extra={
                "request_id": incoming_event.request_id,
                "source_endpoint": incoming_event.source_endpoint,
                "event_type": incoming_event.event_type,
                "external_event_key": incoming_event.external_event_key,
                **incoming_event.trace_context,
            },
        )

        raw_result = self._repository.register_incoming_raw_event(incoming_event)
        if raw_result.duplicate:
            if _should_retry_duplicate_raw(raw_result):
                logger.info(
                    "Retrying failed incoming webhook",
                    extra={
                        "request_id": incoming_event.request_id,
                        "source_endpoint": incoming_event.source_endpoint,
                        "external_event_key": incoming_event.external_event_key,
                        "raw_event_id": raw_result.raw_event_id,
                        "raw_processing_status": raw_result.processing_status,
                        **incoming_event.trace_context,
                    },
                )
            else:
                logger.info(
                    "Duplicate incoming webhook ignored",
                    extra={
                        "request_id": incoming_event.request_id,
                        "source_endpoint": incoming_event.source_endpoint,
                        "external_event_key": incoming_event.external_event_key,
                        "raw_event_id": raw_result.raw_event_id,
                        "raw_processing_status": raw_result.processing_status,
                        **incoming_event.trace_context,
                    },
                )
                return _incoming_response(
                    incoming_event,
                    status="duplicate_ignored",
                    raw_event_id=raw_result.raw_event_id,
                )

        if raw_result.raw_event_id is None:
            raise DatabaseError("Raw incoming webhook event was not persisted")

        try:
            entity_ids = self._repository.save_incoming_event(
                incoming_event,
                raw_result.raw_event_id,
            )
        except Exception as exc:
            try:
                self._repository.mark_raw_failed(raw_result.raw_event_id, str(exc))
            except Exception as mark_error:
                logger.error(
                    "Could not mark raw incoming webhook as failed",
                    extra={
                        "request_id": incoming_event.request_id,
                        "external_event_key": incoming_event.external_event_key,
                        "raw_event_id": raw_result.raw_event_id,
                        "mark_error_type": mark_error.__class__.__name__,
                    },
                )
            raise

        logger.info(
            "Incoming webhook processed",
            extra={
                "request_id": incoming_event.request_id,
                "source_endpoint": incoming_event.source_endpoint,
                "external_event_key": incoming_event.external_event_key,
                "raw_event_id": raw_result.raw_event_id,
                **incoming_event.trace_context,
                **entity_ids,
            },
        )

        return _incoming_response(
            incoming_event,
            status="processed",
            raw_event_id=raw_result.raw_event_id,
            entities=entity_ids,
        )

    def _process_outgoing(self, envelope: WebhookEnvelope) -> dict[str, Any]:
        outgoing_event = self._outgoing_mapper.to_outgoing_event(envelope)

        logger.info(
            "Outgoing webhook mapped",
            extra={
                "request_id": outgoing_event.request_id,
                "source_endpoint": outgoing_event.source_endpoint,
                "event_type": outgoing_event.event_type,
                "external_event_key": outgoing_event.external_event_key,
                **outgoing_event.trace_context,
            },
        )

        raw_result = self._repository.register_outgoing_raw_event(outgoing_event)
        if raw_result.duplicate:
            if _should_retry_duplicate_raw(raw_result):
                logger.info(
                    "Retrying failed outgoing webhook",
                    extra={
                        "request_id": outgoing_event.request_id,
                        "source_endpoint": outgoing_event.source_endpoint,
                        "external_event_key": outgoing_event.external_event_key,
                        "raw_event_id": raw_result.raw_event_id,
                        "raw_processing_status": raw_result.processing_status,
                        **outgoing_event.trace_context,
                    },
                )
            else:
                logger.info(
                    "Duplicate outgoing webhook ignored",
                    extra={
                        "request_id": outgoing_event.request_id,
                        "source_endpoint": outgoing_event.source_endpoint,
                        "external_event_key": outgoing_event.external_event_key,
                        "raw_event_id": raw_result.raw_event_id,
                        "raw_processing_status": raw_result.processing_status,
                        **outgoing_event.trace_context,
                    },
                )
                return _outgoing_response(
                    outgoing_event,
                    status="duplicate_ignored",
                    raw_event_id=raw_result.raw_event_id,
                )

        if raw_result.raw_event_id is None:
            raise DatabaseError("Raw outgoing webhook event was not persisted")

        try:
            entity_ids = self._repository.save_outgoing_event(
                outgoing_event,
                raw_result.raw_event_id,
            )
        except Exception as exc:
            try:
                self._repository.mark_raw_failed(raw_result.raw_event_id, str(exc))
            except Exception as mark_error:
                logger.error(
                    "Could not mark raw outgoing webhook as failed",
                    extra={
                        "request_id": outgoing_event.request_id,
                        "external_event_key": outgoing_event.external_event_key,
                        "raw_event_id": raw_result.raw_event_id,
                        "mark_error_type": mark_error.__class__.__name__,
                    },
                )
            raise

        logger.info(
            "Outgoing webhook processed",
            extra={
                "request_id": outgoing_event.request_id,
                "source_endpoint": outgoing_event.source_endpoint,
                "external_event_key": outgoing_event.external_event_key,
                "raw_event_id": raw_result.raw_event_id,
                **outgoing_event.trace_context,
                **entity_ids,
            },
        )

        return _outgoing_response(
            outgoing_event,
            status="processed",
            raw_event_id=raw_result.raw_event_id,
            entities=entity_ids,
        )


def _incoming_response(
    event: IncomingWebhookEvent,
    *,
    status: str,
    raw_event_id: int | None,
    entities: dict[str, int | None] | None = None,
) -> dict[str, Any]:
    response: dict[str, Any] = {
        "status": status,
        "provider": event.provider_name,
        "endpoint": event.source_endpoint,
        "event_type": event.event_type,
        "request_id": event.request_id,
        "external_event_key": event.external_event_key,
        "message_external_id": event.message_external_id,
        "conversation_external_id": event.conversation_external_id,
        "customer_external_id": event.customer_external_id,
        "raw_event_id": raw_event_id,
    }
    if entities is not None:
        response["entities"] = entities
    return response


def _outgoing_response(
    event: OutgoingWebhookEvent,
    *,
    status: str,
    raw_event_id: int | None,
    entities: dict[str, int | None] | None = None,
) -> dict[str, Any]:
    response: dict[str, Any] = {
        "status": status,
        "provider": event.provider_name,
        "endpoint": event.source_endpoint,
        "event_type": event.event_type,
        "request_id": event.request_id,
        "external_event_key": event.external_event_key,
        "message_external_id": event.message_external_id,
        "conversation_external_id": event.conversation_external_id,
        "customer_external_id": event.customer_external_id,
        "operator_external_id": (
            event.operator.operator_external_id if event.operator is not None else None
        ),
        "raw_event_id": raw_event_id,
    }
    if entities is not None:
        response["entities"] = entities
    return response


def _should_retry_duplicate_raw(raw_result: Any) -> bool:
    return (
        raw_result.raw_event_id is not None
        and raw_result.processing_status in _RETRYABLE_DUPLICATE_RAW_STATUSES
    )
