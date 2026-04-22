import json
from collections.abc import Mapping
from typing import Any

from services.webhook_service import WebhookIngestionService
from utils.events import get_request_id
from utils.exceptions import AppError
from utils.http import error_response, internal_error_response, success_response
from utils.log import get_logger, log_exception

logger = get_logger(__name__)
service = WebhookIngestionService()


def handle_webhook(
    source_endpoint: str,
    event: dict[str, Any],
    context: Any | None = None,
) -> dict[str, Any]:
    request_id = get_request_id(event, context)
    try:
        result = service.process(source_endpoint, event, context)
        return success_response(result, request_id=request_id)
    except AppError as exc:
        logger.warning(
            "Webhook processing failed",
            extra={
                "error_code": exc.error_code,
                "error_message": exc.message,
                "request_id": request_id,
                "source_endpoint": source_endpoint,
                **_payload_shape(event),
            },
        )
        return error_response(exc, request_id=request_id)
    except Exception as exc:
        log_exception(
            logger,
            "Unhandled webhook processing error",
            exc,
            request_id=request_id,
            source_endpoint=source_endpoint,
        )
        return internal_error_response(request_id=request_id)


def _payload_shape(event: Mapping[str, Any]) -> dict[str, Any]:
    if "body" not in event:
        payload = event
    else:
        payload = event.get("body")
        if event.get("isBase64Encoded") or not isinstance(payload, (dict, str)):
            return {}
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except json.JSONDecodeError:
                return {}

    if isinstance(payload, Mapping):
        return {"payload_keys": sorted(str(key) for key in payload.keys())}

    return {}
