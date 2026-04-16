from collections.abc import Mapping
from typing import Any


def get_request_id(event: Mapping[str, Any], context: Any | None = None) -> str | None:
    if context is not None and getattr(context, "aws_request_id", None):
        return str(context.aws_request_id)

    request_context = event.get("requestContext") or {}
    request_id = request_context.get("requestId")
    return str(request_id) if request_id else None
