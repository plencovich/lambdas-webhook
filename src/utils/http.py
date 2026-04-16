import json
from http import HTTPStatus
from typing import Any

from utils.exceptions import AppError


DEFAULT_HEADERS = {
    "Content-Type": "application/json",
}


def json_response(
    status_code: int | HTTPStatus,
    body: dict[str, Any] | list[Any] | str | None = None,
    headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    response_headers = {**DEFAULT_HEADERS, **(headers or {})}

    return {
        "statusCode": int(status_code),
        "headers": response_headers,
        "body": json.dumps(body or {}, default=str, separators=(",", ":")),
    }


def success_response(
    body: dict[str, Any] | list[Any] | str | None = None,
    *,
    status_code: int | HTTPStatus = HTTPStatus.OK,
    request_id: str | None = None,
) -> dict[str, Any]:
    return json_response(
        status_code,
        {
            "success": True,
            "data": body or {},
            "request_id": request_id,
        },
    )


def accepted_response(
    body: dict[str, Any] | list[Any] | str | None = None,
    *,
    request_id: str | None = None,
) -> dict[str, Any]:
    return success_response(
        body,
        status_code=HTTPStatus.ACCEPTED,
        request_id=request_id,
    )


def error_response(
    error: AppError,
    *,
    request_id: str | None = None,
) -> dict[str, Any]:
    return json_response(
        error.status_code,
        {
            "success": False,
            "error": {
                "code": error.error_code,
                "message": error.public_message,
            },
            "request_id": request_id,
        },
    )


def internal_error_response(
    *,
    request_id: str | None = None,
) -> dict[str, Any]:
    return json_response(
        HTTPStatus.INTERNAL_SERVER_ERROR,
        {
            "success": False,
            "error": {
                "code": "internal_error",
                "message": "Unexpected processing error",
            },
            "request_id": request_id,
        },
    )
