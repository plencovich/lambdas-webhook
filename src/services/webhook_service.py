from collections.abc import Mapping
from typing import Any

from mappers.status_mapper import StatusPayloadMapper
from mappers.webhook_mapper import WebhookMapper
from models.webhook_event import WebhookEnvelope
from repositories.webhook_repository import WebhookRepository
from utils.exceptions import DatabaseError
from utils.log import get_logger
from utils.payload import parse_json_body

logger = get_logger(__name__)


class WebhookIngestionService:
    def __init__(
        self,
        mapper: WebhookMapper | None = None,
        status_mapper: StatusPayloadMapper | None = None,
        repository: WebhookRepository | None = None,
    ) -> None:
        self._mapper = mapper or WebhookMapper()
        self._status_mapper = status_mapper or StatusPayloadMapper()
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
        envelope = self._mapper.to_envelope(source_endpoint, event, payload, context)

        if source_endpoint == "status":
            return self._process_status(envelope)

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
