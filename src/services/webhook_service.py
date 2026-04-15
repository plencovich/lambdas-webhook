from collections.abc import Mapping
from typing import Any

from mappers.webhook_mapper import WebhookMapper
from repositories.webhook_repository import WebhookRepository
from utils.log import get_logger
from utils.payload import parse_json_body

logger = get_logger(__name__)


class WebhookIngestionService:
    def __init__(
        self,
        mapper: WebhookMapper | None = None,
        repository: WebhookRepository | None = None,
    ) -> None:
        self._mapper = mapper or WebhookMapper()
        self._repository = repository or WebhookRepository()

    def process(
        self,
        source_endpoint: str,
        event: Mapping[str, Any],
        context: Any | None = None,
    ) -> dict[str, Any]:
        payload = parse_json_body(event)
        envelope = self._mapper.to_envelope(source_endpoint, event, payload, context)

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
