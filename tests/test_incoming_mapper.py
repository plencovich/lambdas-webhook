import json
import sys
import unittest
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from mappers.incoming_mapper import IncomingPayloadMapper
from models.webhook_event import WebhookEnvelope
from services.webhook_service import WebhookIngestionService


FIXTURES_DIR = ROOT / "tests" / "fixtures" / "incoming"


def load_payload(name: str) -> dict:
    return json.loads((FIXTURES_DIR / name).read_text())


def map_payload(payload: dict):
    envelope = WebhookEnvelope(
        provider_name="botmaker",
        source_endpoint="incoming",
        payload=payload,
        received_at=datetime(2026, 4, 17, 18, 30, tzinfo=UTC),
        request_id="test-request",
        event_type="unknown",
        idempotency_key=None,
        headers={},
    )
    return IncomingPayloadMapper().to_incoming_event(envelope)


class FakeDuplicateRepository:
    def __init__(self):
        self.save_called = False

    def register_incoming_raw_event(self, event):
        return type(
            "RawResult",
            (),
            {"raw_event_id": 123, "duplicate": True, "processing_status": "processed"},
        )()

    def save_incoming_event(self, event, raw_event_id):
        self.save_called = True
        return {}


class FakePersistingRepository:
    def __init__(self):
        self.saved_event = None
        self.saved_raw_event_id = None

    def register_incoming_raw_event(self, event):
        return type(
            "RawResult",
            (),
            {"raw_event_id": 456, "duplicate": False, "processing_status": "processing"},
        )()

    def save_incoming_event(self, event, raw_event_id):
        self.saved_event = event
        self.saved_raw_event_id = raw_event_id
        return {
            "customer_id": 10,
            "operator_id": None,
            "conversation_id": 20,
            "message_id": 30,
        }


class IncomingMapperTest(unittest.TestCase):
    def test_maps_simple_incoming_message(self):
        event = map_payload(load_payload("incoming-01.json"))

        self.assertEqual(event.event_type, "incoming_message")
        self.assertEqual(event.message.message_external_id, "51FH77RLXF1BZIEHOLMQ")
        self.assertEqual(event.conversation.conversation_external_id, event.conversation_external_id)
        self.assertEqual(event.conversation_external_id, "NWHAYJVORB4TSWTBY3PQ_2026-04-17T18:37:29.922Z")
        self.assertEqual(event.customer.customer_external_id, "NWHAYJVORB4TSWTBY3PQ")
        self.assertEqual(event.customer.contact_external_id, "5493584232743")
        self.assertEqual(event.customer.business_channel_address, "5491171017096")
        self.assertEqual(event.customer.customer_first_name, "Hanan")
        self.assertEqual(event.customer.customer_last_name, "Pacha Itinerante")
        self.assertEqual(event.message.direction, "inbound")
        self.assertEqual(event.message.sender_type, "customer")
        self.assertEqual(event.message.message_text, "Buenas tardes")
        self.assertFalse(event.message.is_button)
        self.assertTrue(event.message.is_customer_message)
        self.assertEqual(event.message.queue_name, "Seguros-1")

    def test_maps_button_message(self):
        event = map_payload(load_payload("incoming-02.json"))

        self.assertEqual(event.message.message_external_id, "ZMQUBHQQFPXBE53LQF5Q")
        self.assertTrue(event.message.is_button)
        self.assertEqual(event.message.button_label, "Cotizar")
        self.assertEqual(event.message.message_text, "Cotizar")

    def test_external_event_key_uses_message_id_for_idempotency(self):
        payload = load_payload("incoming-01.json")
        event = map_payload(payload)

        retried_payload = {**payload, "message": "texto cambiado por retry defectuoso"}
        retried_event = map_payload(retried_payload)

        self.assertEqual(event.external_event_key, retried_event.external_event_key)
        self.assertEqual(
            event.external_event_key,
            "incoming:v1:botmaker:message:51FH77RLXF1BZIEHOLMQ",
        )

    def test_service_ignores_duplicate_raw_event_without_normalizing_again(self):
        repository = FakeDuplicateRepository()
        service = WebhookIngestionService(repository=repository)
        response = service.process(
            "incoming",
            {
                "body": json.dumps(load_payload("incoming-01.json")),
                "requestContext": {"requestId": "local-test"},
            },
        )

        self.assertEqual(response["status"], "duplicate_ignored")
        self.assertEqual(response["raw_event_id"], 123)
        self.assertFalse(repository.save_called)

    def test_service_persists_customer_conversation_and_message_for_new_event(self):
        repository = FakePersistingRepository()
        service = WebhookIngestionService(repository=repository)
        response = service.process(
            "incoming",
            {
                "body": json.dumps(load_payload("incoming-02.json")),
                "requestContext": {"requestId": "local-test"},
            },
        )

        self.assertEqual(response["status"], "processed")
        self.assertEqual(response["raw_event_id"], 456)
        self.assertEqual(
            response["entities"],
            {"customer_id": 10, "operator_id": None, "conversation_id": 20, "message_id": 30},
        )
        self.assertEqual(repository.saved_raw_event_id, 456)
        self.assertEqual(repository.saved_event.customer.customer_external_id, "NWHAYJVORB4TSWTBY3PQ")
        self.assertEqual(
            repository.saved_event.conversation.conversation_external_id,
            "NWHAYJVORB4TSWTBY3PQ_2026-04-17T18:37:29.922Z",
        )
        self.assertEqual(repository.saved_event.message.message_external_id, "ZMQUBHQQFPXBE53LQF5Q")

    def test_all_real_fixtures_are_mappable(self):
        for path in sorted(FIXTURES_DIR.glob("incoming-*.json")):
            with self.subTest(path=path.name):
                event = map_payload(load_payload(path.name))
                self.assertEqual(event.provider_name, "botmaker")
                self.assertEqual(event.source_endpoint, "incoming")
                self.assertEqual(event.event_type, "incoming_message")
                self.assertTrue(event.external_event_key.startswith("incoming:v1:botmaker:message:"))
                self.assertEqual(event.customer.customer_external_id, "NWHAYJVORB4TSWTBY3PQ")
                self.assertEqual(event.conversation.current_queue_name, "Seguros-1")
                self.assertIsNotNone(event.message.message_at)


if __name__ == "__main__":
    unittest.main()
