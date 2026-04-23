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
        received_at=datetime(2026, 4, 22, 15, 0, tzinfo=UTC),
        request_id="test-request",
        event_type="unknown",
        idempotency_key=None,
        headers={},
    )
    return StatusPayloadMapper().to_status_event(envelope)


class StatusMapperTest(unittest.TestCase):
    def test_maps_file_attachment_in_last_message(self):
        event = map_payload(load_payload("status-15.json"))

        self.assertIsNotNone(event.message)
        self.assertTrue(event.message.has_attachment)
        self.assertEqual(event.message.attachment_type, "file")
        self.assertIn(".xlsx", event.message.attachment_url)
        self.assertEqual(event.message.delivery_status, "delivered")

    def test_keeps_only_allowlisted_context_keys_and_excludes_pii(self):
        event = map_payload(
            {
                "_id_": "customer-1",
                "STATUS": "read",
                "STATUS_CHANGE_TIME": "2026-04-22T15:05:00Z",
                "FIRST_NAME": "undefined",
                "LAST_NAME": "null",
                "country": "AR",
                "locale": " none ",
                "gender": "NULL",
                "PLATFORM_CONTACT_ID": "5491111111111",
                "CHAT_PLATFORM_ID": "whatsapp",
                "chatChannelId": "mecubro-whatsapp-5491171017096",
                "WHATSAPP_NUMBER": "5491171017096",
                "CREATION_TIME": "2026-04-22T14:00:00Z",
                "BUSINESS_ID": "mecubro",
                "AP_Actividad": "Fotografía",
                "ActividadCode": "1944021682",
                "ActividadName": "Fotografo",
                "BusquedaActividad": "1",
                "IssueResuelto": "Si",
                "AP_Price_Total": "620",
                "AP_QuoteId": "quote-1",
                "AP_CoverageId": "coverage-1",
                "PreguntarAccionCompleta": "¿Pudiste avanzar?",
                "RespuestaAccionCompleta": "Listo",
                "AP_User_Password": "secret",
                "AP_DNITomador": "12345678",
                "AP_User_Nombre": "Juan",
                "AP_User_Apellido": "Perez",
                "AP_User_Calle": "Siempre Viva",
                "AP_User_CP": "5000",
                "AP_MailTomador": "mail@example.com",
                "LAST_MESSAGE": {
                    "_id_": "message-1",
                    "date": "2026-04-22T15:04:00Z",
                    "from": "bot",
                    "message": "Hola",
                    "customerId": "customer-1",
                    "sessionId": "conversation-1",
                    "contactId": "5491111111111",
                    "chatPlatform": "whatsapp",
                    "sessionCreationTime": "2026-04-22T14:00:00Z",
                },
                "EXECUTED_INTENTS": [],
                "BOT_MUTED": False,
                "PENDING_MSGS": 0,
            }
        )

        self.assertEqual(
            event.context.context_json,
            {
                "AP_Actividad": "Fotografía",
                "ActividadCode": "1944021682",
                "ActividadName": "Fotografo",
                "BusquedaActividad": "1",
                "IssueResuelto": "Si",
                "AP_Price_Total": "620",
                "AP_QuoteId": "quote-1",
                "AP_CoverageId": "coverage-1",
                "PreguntarAccionCompleta": "¿Pudiste avanzar?",
                "RespuestaAccionCompleta": "Listo",
            },
        )
        self.assertEqual(event.context.activity_name, "Fotografo")
        self.assertIsNone(event.context.product)
        self.assertIsNone(event.conversation.product)
        self.assertTrue(event.conversation.resolved_flag)
        self.assertIsNone(event.customer.customer_first_name)
        self.assertIsNone(event.customer.customer_last_name)
        self.assertIsNone(event.customer.customer_locale)
        self.assertIsNone(event.customer.customer_gender)

    def test_all_real_status_fixtures_are_mappable(self):
        for path in sorted(FIXTURES_DIR.glob("status-*.json")):
            with self.subTest(path=path.name):
                event = map_payload(load_payload(path.name))
                self.assertEqual(event.provider_name, "botmaker")
                self.assertEqual(event.source_endpoint, "status")
                self.assertEqual(event.event_type, "message_status_snapshot")
                self.assertTrue(event.external_event_key.startswith("status:v1:"))
                self.assertIsNotNone(event.snapshot.snapshot_at)
                self.assertIn(event.snapshot.status_current, {"read", "delivered"})
                self.assertIsNotNone(event.customer.customer_external_id)


if __name__ == "__main__":
    unittest.main()
