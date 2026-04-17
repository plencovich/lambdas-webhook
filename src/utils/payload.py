import base64
import json
from collections.abc import Mapping
from typing import Any

from utils.exceptions import ValidationError


class InvalidJsonPayload(ValidationError):
    error_code = "invalid_json_payload"


def parse_json_body(event: Mapping[str, Any]) -> dict[str, Any]:
    if "body" not in event:
        return dict(event)

    body = event.get("body")

    if body is None or body == "":
        return {}

    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")

    if isinstance(body, dict):
        return body

    if not isinstance(body, str):
        raise InvalidJsonPayload("Request body must be a JSON object")

    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise InvalidJsonPayload("Request body must be valid JSON") from exc

    if not isinstance(payload, dict):
        raise InvalidJsonPayload("Request body must be a JSON object")

    return payload
