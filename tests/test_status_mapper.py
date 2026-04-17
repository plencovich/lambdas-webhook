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
    def test_external_event_key_distinguishes_delivered_and_read_for_same_message(self):
        delivered = map_payload(load_payload("response-01.json"))
        read = map_payload(load_payload("response-02.json"))

        self.assertEqual(delivered.message.message_external_id, read.message.message_external_id)
        self.assertEqual(delivered.conversation_external_id, read.conversation_external_id)
        self.assertEqual(delivered.snapshot.snapshot_at, read.snapshot.snapshot_at)
        self.assertNotEqual(delivered.external_event_key, read.external_event_key)

    def test_maps_customer_button_message(self):
        event = map_payload(load_payload("response-01.json"))

        self.assertEqual(event.customer.customer_external_id, "IFPQW13ATPZK7FRZFJZH")
        self.assertEqual(
            event.conversation_external_id,
            "IFPQW13ATPZK7FRZFJZH_2026-04-17T13:32:23.665Z",
        )
        self.assertEqual(event.message.sender_type, "customer")
        self.assertEqual(event.message.direction, "inbound")
        self.assertTrue(event.message.is_button)
        self.assertEqual(event.message.button_label, "No")
        self.assertTrue(event.message.is_customer_message)

    def test_maps_operator_audio_attachment(self):
        event = map_payload(load_payload("response-10.json"))

        self.assertEqual(event.message.sender_type, "operator")
        self.assertEqual(event.message.direction, "outbound")
        self.assertTrue(event.message.has_attachment)
        self.assertEqual(event.message.attachment_type, "audio")
        self.assertIn("storage.googleapis.com", event.message.attachment_url)
        self.assertEqual(event.operator.operator_external_id, "wkNe9pzSpzW7D01bzsP53wAhGpb2")
        self.assertEqual(event.operator.operator_email, "sofia.jacobi@mecubro.com")

    def test_extracts_dynamic_context_without_promoting_sensitive_fields(self):
        event = map_payload(load_payload("response-01.json"))

        self.assertEqual(event.context.quote_external_id, "1824465133")
        self.assertEqual(event.context.coverage_external_id, "1853152764")
        self.assertEqual(str(event.context.quoted_total_amount), "2290.84")
        self.assertEqual(event.context.activity_name, "Fotografo")
        self.assertIn("AP_QuoteId", event.context.context_json)
        self.assertIn("IssueResuelto", event.context.context_json)
        self.assertNotIn("AP_MailTomador", event.context.context_json)
        self.assertNotIn("AP_TipoDocumentoTomador", event.context.context_json)

    def test_all_real_fixtures_are_mappable(self):
        for path in sorted(FIXTURES_DIR.glob("response-*.json")):
            with self.subTest(path=path.name):
                event = map_payload(load_payload(path.name))
                self.assertEqual(event.provider_name, "botmaker")
                self.assertEqual(event.source_endpoint, "status")
                self.assertEqual(event.event_type, "message_status_snapshot")
                self.assertTrue(event.external_event_key.startswith("status:v1:"))
                self.assertIsNotNone(event.snapshot.snapshot_at)


if __name__ == "__main__":
    unittest.main()
