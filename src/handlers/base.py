from http import HTTPStatus
from typing import Any

from services.webhook_service import WebhookIngestionService
from utils.http import json_response
from utils.log import get_logger
from utils.payload import InvalidJsonPayload

logger = get_logger(__name__)
service = WebhookIngestionService()


def handle_webhook(
    source_endpoint: str,
    event: dict[str, Any],
    context: Any | None = None,
) -> dict[str, Any]:
    try:
        result = service.process(source_endpoint, event, context)
        return json_response(HTTPStatus.ACCEPTED, result)
    except InvalidJsonPayload as exc:
        logger.warning("Invalid JSON payload: %s", exc)
        return json_response(
            HTTPStatus.BAD_REQUEST,
            {
                "error": "invalid_json",
                "message": str(exc),
            },
        )
    except Exception:
        logger.exception("Unhandled webhook processing error")
        return json_response(
            HTTPStatus.INTERNAL_SERVER_ERROR,
            {
                "error": "internal_error",
                "message": "Unexpected webhook processing error",
            },
        )
