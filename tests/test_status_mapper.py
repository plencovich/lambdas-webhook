import json
import sys
import unittest
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from mappers.status_mapper import StatusPayloadMapper
from models.webhook_event import WebhookEnvelope


FIXTURES_DIR = ROOT / "tests" / "fixtures" / "status"


def load_payload(name: str) -> dict:
    return json.loads((FIXTURES_DIR / name).read_text())


def map_payload(payload: dict):
    envelope = WebhookEnvelope(
        provider_name="botmaker",
        source_endpoint="status",
        payload=payload,
        received_at=datetime(2026, 4, 17, 15, 30, tzinfo=UTC),
        request_id="test-request",
        event_type="unknown",
        idempotency_key=None,
        headers={},
    )
    return StatusPayloadMapper().to_status_event(envelope)


class StatusMapperTest(unittest.TestCase):
    def test_external_event_key_distinguishes_repeated_status_snapshots_for_same_message(self):
        first_snapshot = map_payload(load_payload("status-07.json"))
        later_snapshot = map_payload(load_payload("status-08.json"))

        self.assertEqual(first_snapshot.message.message_external_id, later_snapshot.message.message_external_id)
        self.assertEqual(first_snapshot.conversation_external_id, later_snapshot.conversation_external_id)
        self.assertEqual(first_snapshot.snapshot.status_current, later_snapshot.snapshot.status_current)
        self.assertNotEqual(first_snapshot.snapshot.snapshot_at, later_snapshot.snapshot.snapshot_at)
        self.assertNotEqual(first_snapshot.external_event_key, later_snapshot.external_event_key)

    def test_maps_bot_message_snapshot(self):
        event = map_payload(load_payload("status-01.json"))

        self.assertEqual(event.customer.customer_external_id, "NWHAYJVORB4TSWTBY3PQ")
        self.assertEqual(
            event.conversation_external_id,
            "NWHAYJVORB4TSWTBY3PQ_2026-04-17T18:37:29.922Z",
        )
        self.assertEqual(event.message.sender_type, "bot")
        self.assertEqual(event.message.direction, "outbound")
        self.assertFalse(event.message.is_button)
        self.assertFalse(event.message.is_customer_message)

    def test_maps_operator_audio_attachment(self):
        event = map_payload(load_payload("status-21.json"))

        self.assertEqual(event.message.sender_type, "operator")
        self.assertEqual(event.message.direction, "outbound")
        self.assertTrue(event.message.has_attachment)
        self.assertEqual(event.message.attachment_type, "audio")
        self.assertIn("storage.googleapis.com", event.message.attachment_url)
        self.assertEqual(event.operator.operator_external_id, "yucPtGbocIQnnJzTjinZpUtrEbq1")
        self.assertEqual(event.operator.operator_email, "vanesa.morales@mecubro.com")

    def test_extracts_dynamic_context_without_promoting_sensitive_fields(self):
        event = map_payload(load_payload("status-01.json"))

        self.assertIsNone(event.context.quote_external_id)
        self.assertIsNone(event.context.coverage_external_id)
        self.assertIn("RespuestaAccionCompleta", event.context.context_json)
        self.assertNotIn("AP_MailTomador", event.context.context_json)
        self.assertNotIn("AP_TipoDocumentoTomador", event.context.context_json)

    def test_all_real_fixtures_are_mappable(self):
        for path in sorted(FIXTURES_DIR.glob("status-*.json")):
            with self.subTest(path=path.name):
                event = map_payload(load_payload(path.name))
                self.assertEqual(event.provider_name, "botmaker")
                self.assertEqual(event.source_endpoint, "status")
                self.assertEqual(event.event_type, "message_status_snapshot")
                self.assertTrue(event.external_event_key.startswith("status:v1:"))
                self.assertIsNotNone(event.snapshot.snapshot_at)


if __name__ == "__main__":
    unittest.main()
