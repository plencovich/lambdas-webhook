from typing import Any

from handlers.base import handle_webhook


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    return handle_webhook("incoming", event, context)
