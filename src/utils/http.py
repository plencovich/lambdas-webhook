import json
from typing import Any


DEFAULT_HEADERS = {
    "Content-Type": "application/json",
}


def json_response(
    status_code: int,
    body: dict[str, Any] | list[Any] | str | None = None,
    headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    response_headers = {**DEFAULT_HEADERS, **(headers or {})}

    return {
        "statusCode": int(status_code),
        "headers": response_headers,
        "body": json.dumps(body or {}, default=str, separators=(",", ":")),
    }
