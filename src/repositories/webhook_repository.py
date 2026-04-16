from models.webhook_event import WebhookEnvelope
from repositories.base import BaseRepository


class WebhookRepository(BaseRepository):
    def save_raw_event(self, envelope: WebhookEnvelope) -> None:
        """Placeholder for future insert into webhook_events_raw."""
        _ = envelope
        return None
