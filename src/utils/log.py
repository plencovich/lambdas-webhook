import json
import logging
from datetime import UTC, datetime
from typing import Any

from utils.config import get_app_config

_RESERVED_LOG_RECORD_KEYS = {
    "args",
    "asctime",
    "created",
    "exc_info",
    "exc_text",
    "filename",
    "funcName",
    "levelname",
    "levelno",
    "lineno",
    "message",
    "module",
    "msecs",
    "msg",
    "name",
    "pathname",
    "process",
    "processName",
    "relativeCreated",
    "stack_info",
    "taskName",
    "thread",
    "threadName",
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "module": record.module,
            "function": record.funcName,
            "line": record.lineno,
        }

        for key, value in record.__dict__.items():
            if key not in _RESERVED_LOG_RECORD_KEYS and not key.startswith("_"):
                payload[key] = value

        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)

        return json.dumps(payload, default=str, separators=(",", ":"))


class StructuredLogger(logging.LoggerAdapter):
    def bind(self, **context: Any) -> "StructuredLogger":
        return StructuredLogger(self.logger, {**self.extra, **context})

    def process(
        self,
        msg: str,
        kwargs: dict[str, Any],
    ) -> tuple[str, dict[str, Any]]:
        extra = kwargs.get("extra") or {}
        kwargs["extra"] = {**self.extra, **extra}
        return msg, kwargs


def configure_logging() -> None:
    app_config = get_app_config()
    level = getattr(logging, app_config.log_level, logging.INFO)
    root_logger = logging.getLogger()
    root_logger.setLevel(level)

    if not root_logger.handlers:
        handler = logging.StreamHandler()
        root_logger.addHandler(handler)

    formatter = JsonFormatter()
    for handler in root_logger.handlers:
        handler.setFormatter(formatter)
        handler.setLevel(level)


def get_logger(name: str, **context: Any) -> StructuredLogger:
    configure_logging()
    logger = logging.getLogger(name)
    logger.setLevel(logging.getLogger().level)
    return StructuredLogger(logger, context)


def log_exception(
    logger: logging.LoggerAdapter,
    message: str,
    exc: Exception,
    **context: Any,
) -> None:
    logger.exception(
        message,
        extra={
            "exception_type": exc.__class__.__name__,
            **context,
        },
    )
