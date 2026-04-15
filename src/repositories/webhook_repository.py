from collections.abc import Callable
from typing import Any

from db.connection import get_connection
from models.webhook_event import WebhookEnvelope


class WebhookRepository:
    def __init__(self, connection_factory: Callable[[], Any] = get_connection) -> None:
        self._connection_factory = connection_factory

    def save_raw_event(self, envelope: WebhookEnvelope) -> None:
        """Placeholder for future insert into webhook_events_raw."""
        _ = envelope
        return None
