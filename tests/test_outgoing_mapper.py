import json
import sys
import unittest
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from mappers.outgoing_mapper import OutgoingPayloadMapper
from models.webhook_event import WebhookEnvelope
from services.webhook_service import WebhookIngestionService


FIXTURES_DIR = ROOT / "tests" / "fixtures" / "outgoing"


def load_payload(name: str) -> dict:
    return json.loads((FIXTURES_DIR / name).read_text())


def map_payload(payload: dict):
    envelope = WebhookEnvelope(
        provider_name="botmaker",
        source_endpoint="outgoing",
        payload=payload,
        received_at=datetime(2026, 4, 17, 18, 30, tzinfo=UTC),
        request_id="test-request",
        event_type="unknown",
        idempotency_key=None,
        headers={},
    )
    return OutgoingPayloadMapper().to_outgoing_event(envelope)


class FakeDuplicateRepository:
    def __init__(self):
        self.save_called = False

    def register_outgoing_raw_event(self, event):
        return type(
            "RawResult",
            (),
            {"raw_event_id": 123, "duplicate": True, "processing_status": "processed"},
        )()

    def save_outgoing_event(self, event, raw_event_id):
        self.save_called = True
        return {}


class FakePersistingRepository:
    def __init__(self):
        self.saved_event = None
        self.saved_raw_event_id = None

    def register_outgoing_raw_event(self, event):
        return type(
            "RawResult",
            (),
            {"raw_event_id": 456, "duplicate": False, "processing_status": "processing"},
        )()

    def save_outgoing_event(self, event, raw_event_id):
        self.saved_event = event
        self.saved_raw_event_id = raw_event_id
        return {
            "customer_id": 10,
            "operator_id": 11,
            "conversation_id": 20,
            "message_id": 30,
        }


class FakeFailedDuplicateRepository(FakePersistingRepository):
    def register_outgoing_raw_event(self, event):
        return type(
            "RawResult",
            (),
            {"raw_event_id": 789, "duplicate": True, "processing_status": "failed"},
        )()


class OutgoingMapperTest(unittest.TestCase):
    def test_maps_operator_text_message(self):
        event = map_payload(load_payload("outgoing-01.json"))

        self.assertEqual(event.event_type, "outgoing_message")
        self.assertEqual(event.message.message_external_id, "CK7YUGAQQ1NBRBJQNB22")
        self.assertEqual(event.conversation_external_id, "NWHAYJVORB4TSWTBY3PQ_2026-04-17T18:37:29.922Z")
        self.assertEqual(event.customer.customer_external_id, "NWHAYJVORB4TSWTBY3PQ")
        self.assertEqual(event.customer.contact_external_id, "5493584232743")
        self.assertEqual(event.customer.business_channel_address, "5491171017096")
        self.assertEqual(event.message.direction, "outbound")
        self.assertEqual(event.message.sender_type, "operator")
        self.assertEqual(event.message.sender_name, "Sofia Jacobi")
        self.assertFalse(event.message.is_customer_message)
        self.assertEqual(event.message.queue_name, "Seguros-1")
        self.assertEqual(event.operator.operator_external_id, "wkNe9pzSpzW7D01bzsP53wAhGpb2")
        self.assertEqual(event.operator.operator_email, "sofia.jacobi@mecubro.com")
        self.assertEqual(event.conversation.first_human_response_at, event.message.message_at)
        self.assertIsNone(event.conversation.status_current)

    def test_external_event_key_uses_message_id_for_idempotency(self):
        event = map_payload(load_payload("outgoing-05.json"))
        duplicated = map_payload(load_payload("outgoing-06.json"))

        self.assertEqual(event.external_event_key, duplicated.external_event_key)
        self.assertEqual(
            event.external_event_key,
            "outgoing:v1:botmaker:message:XCMD7TIOMX81RXAH6V5A",
        )

    def test_maps_file_attachment_without_text(self):
        event = map_payload(load_payload("outgoing-07.json"))

        self.assertTrue(event.message.has_attachment)
        self.assertEqual(event.message.attachment_type, "file")
        self.assertIn(".xlsx", event.message.attachment_url)
        self.assertIsNone(event.message.message_text)

    def test_maps_audio_attachment_without_text(self):
        event = map_payload(load_payload("outgoing-13.json"))

        self.assertTrue(event.message.has_attachment)
        self.assertEqual(event.message.attachment_type, "audio")
        self.assertIn("storage.googleapis.com", event.message.attachment_url)
        self.assertIsNone(event.message.message_text)

    def test_maps_image_attachment_without_text(self):
        event = map_payload(
            {
                "WHATSAPP_NUMBER": "5491171017096",
                "_id_": "image-only-message",
                "chatPlatform": "whatsapp",
                "contactId": "5493584232743",
                "customerId": "NWHAYJVORB4TSWTBY3PQ",
                "date": "2026-04-22T15:44:35.332193+00:00",
                "from": "operator",
                "fromName": "Vanesa Morales",
                "hasAttachment": True,
                "image": "https://storage.googleapis.com/storage.botmaker.com/public/res/mecubro/agents/example-image.jpg",
                "operatorEmail": "vanesa.morales@mecubro.com",
                "operatorId": "yucPtGbocIQnnJzTjinZpUtrEbq1",
                "operatorName": "Vanesa Morales",
                "queue": "Seguros-1",
                "sessionCreationTime": "2026-04-17T18:37:29.922Z",
                "sessionId": "NWHAYJVORB4TSWTBY3PQ_2026-04-17T18:37:29.922Z",
            }
        )

        self.assertTrue(event.message.has_attachment)
        self.assertEqual(event.message.attachment_type, "image")
        self.assertIn("example-image.jpg", event.message.attachment_url)
        self.assertIsNone(event.message.message_text)

    def test_service_ignores_duplicate_raw_event_without_normalizing_again(self):
        repository = FakeDuplicateRepository()
        service = WebhookIngestionService(repository=repository)
        response = service.process(
            "outgoing",
            {
                "body": json.dumps(load_payload("outgoing-01.json")),
                "requestContext": {"requestId": "local-test"},
            },
        )

        self.assertEqual(response["status"], "duplicate_ignored")
        self.assertEqual(response["raw_event_id"], 123)
        self.assertFalse(repository.save_called)

    def test_service_persists_operator_conversation_and_message_for_new_event(self):
        repository = FakePersistingRepository()
        service = WebhookIngestionService(repository=repository)
        response = service.process(
            "outgoing",
            {
                "body": load_payload("outgoing-02.json"),
                "requestContext": {"requestId": "local-test"},
            },
        )

        self.assertEqual(response["status"], "processed")
        self.assertEqual(response["raw_event_id"], 456)
        self.assertEqual(
            response["entities"],
            {"customer_id": 10, "operator_id": 11, "conversation_id": 20, "message_id": 30},
        )
        self.assertEqual(response["operator_external_id"], "wkNe9pzSpzW7D01bzsP53wAhGpb2")
        self.assertEqual(repository.saved_raw_event_id, 456)
        self.assertEqual(repository.saved_event.operator.operator_name, "Sofia Jacobi")
        self.assertEqual(repository.saved_event.message.direction, "outbound")
        self.assertEqual(repository.saved_event.message.sender_type, "operator")

    def test_service_retries_failed_duplicate_raw_event(self):
        repository = FakeFailedDuplicateRepository()
        service = WebhookIngestionService(repository=repository)
        response = service.process(
            "outgoing",
            {
                "body": json.dumps(load_payload("outgoing-01.json")),
                "requestContext": {"requestId": "local-test"},
            },
        )

        self.assertEqual(response["status"], "processed")
        self.assertEqual(response["raw_event_id"], 789)
        self.assertEqual(repository.saved_raw_event_id, 789)
        self.assertEqual(repository.saved_event.message.message_external_id, "CK7YUGAQQ1NBRBJQNB22")

    def test_all_real_fixtures_are_mappable(self):
        seen_keys = set()
        duplicate_keys = set()

        for path in sorted(FIXTURES_DIR.glob("outgoing-*.json")):
            with self.subTest(path=path.name):
                event = map_payload(load_payload(path.name))
                self.assertEqual(event.provider_name, "botmaker")
                self.assertEqual(event.source_endpoint, "outgoing")
                self.assertEqual(event.event_type, "outgoing_message")
                self.assertTrue(event.external_event_key.startswith("outgoing:v1:botmaker:message:"))
                self.assertEqual(event.message.direction, "outbound")
                self.assertEqual(event.message.sender_type, "operator")
                self.assertIsNotNone(event.operator)
                self.assertIsNotNone(event.message.message_at)
                self.assertEqual(event.conversation.current_queue_name, "Seguros-1")

                if event.external_event_key in seen_keys:
                    duplicate_keys.add(event.external_event_key)
                seen_keys.add(event.external_event_key)

        self.assertEqual(duplicate_keys, {"outgoing:v1:botmaker:message:XCMD7TIOMX81RXAH6V5A"})


if __name__ == "__main__":
    unittest.main()
