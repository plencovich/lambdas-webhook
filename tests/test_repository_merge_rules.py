import json
import sys
import unittest
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from models.status_event import StatusContext, StatusMessage
from repositories.webhook_repository import WebhookRepository


class FakeCursor:
    def __init__(
        self,
        *,
        message_response=None,
        context_response=None,
        lastrowid=0,
    ):
        self.message_response = message_response
        self.context_response = context_response
        self.lastrowid = lastrowid
        self.executions = []
        self._last_query = ""

    def execute(self, query, params=None):
        self._last_query = query
        self.executions.append((query, params))
        return 1

    def fetchone(self):
        if "FROM messages" in self._last_query:
            return self.message_response
        if "FROM conversation_contexts" in self._last_query:
            return self.context_response
        return None


class RepositoryMergeRulesTest(unittest.TestCase):
    def setUp(self):
        self.repository = WebhookRepository(connection_factory=lambda: None)

    def test_upsert_message_preserves_rich_payload_and_specific_attachment_type_for_status(self):
        cursor = FakeCursor(
            message_response={
                "id": 11,
                "attachment_type": "file",
                "attachment_url": "https://example.com/original.pdf",
                "client_payload": json.dumps({"outgoing_message": {"message": "rich payload"}}),
                "message_text": "Adjunto archivo",
                "sender_name": "Vanesa Morales",
                "queue_name": "Seguros-1",
            },
            lastrowid=99,
        )
        event = SimpleNamespace(
            source_endpoint="status",
            message=StatusMessage(
                provider_name="botmaker",
                message_external_id="message-123",
                message_at=datetime(2026, 4, 22, 15, 0, 0),
                direction="outbound",
                sender_type="operator",
                sender_name="Vanesa Morales",
                message_text=None,
                is_button=False,
                button_label=None,
                is_customer_message=False,
                has_attachment=True,
                attachment_type="attachment",
                attachment_url="https://example.com/status.pdf",
                intent_name=None,
                queue_name="Seguros-1",
                delivery_status="read",
                delivery_status_at=datetime(2026, 4, 22, 15, 0, 5),
                client_payload={"last_message": {"message": "poorer payload"}},
            ),
        )

        message_id = self.repository._upsert_message(cursor, event, 1, 1, 1)

        self.assertEqual(message_id, 99)
        self.assertEqual(len(cursor.executions), 2)
        _, insert_params = cursor.executions[-1]
        self.assertEqual(insert_params[14], "file")
        self.assertEqual(
            json.loads(insert_params[20]),
            {"outgoing_message": {"message": "rich payload"}},
        )
        self.assertEqual(insert_params[18], "read")
        self.assertEqual(insert_params[19], datetime(2026, 4, 22, 15, 0, 5))

    def test_upsert_message_can_upgrade_generic_attachment_type_when_status_is_more_specific(self):
        cursor = FakeCursor(
            message_response={
                "id": 11,
                "attachment_type": "attachment",
                "attachment_url": "https://example.com/original.bin",
                "client_payload": json.dumps({"last_message": {"message": "old payload"}}),
                "message_text": None,
                "sender_name": "Vanesa Morales",
                "queue_name": "Seguros-1",
            },
            lastrowid=101,
        )
        event = SimpleNamespace(
            source_endpoint="status",
            message=StatusMessage(
                provider_name="botmaker",
                message_external_id="message-456",
                message_at=datetime(2026, 4, 22, 15, 30, 0),
                direction="outbound",
                sender_type="operator",
                sender_name="Vanesa Morales",
                message_text=None,
                is_button=False,
                button_label=None,
                is_customer_message=False,
                has_attachment=True,
                attachment_type="file",
                attachment_url="https://example.com/status.xlsx",
                intent_name=None,
                queue_name="Seguros-1",
                delivery_status="delivered",
                delivery_status_at=datetime(2026, 4, 22, 15, 30, 2),
                client_payload={"last_message": {"file": "https://example.com/status.xlsx"}},
            ),
        )

        self.repository._upsert_message(cursor, event, 1, 1, 1)

        _, insert_params = cursor.executions[-1]
        self.assertEqual(insert_params[14], "file")
        self.assertEqual(
            json.loads(insert_params[20]),
            {"last_message": {"file": "https://example.com/status.xlsx"}},
        )

    def test_insert_context_skips_identical_consecutive_context(self):
        cursor = FakeCursor(
            context_response={
                "id": 55,
                "snapshot_at": datetime(2026, 4, 22, 14, 0, 0),
                "product": None,
                "topic": None,
                "subtopic": None,
                "quote_external_id": "quote-1",
                "coverage_external_id": "coverage-1",
                "quoted_total_amount": Decimal("620.00"),
                "quote_description": "Seguro AP",
                "activity_name": "Fotografo",
                "completion_message_text": "Listo",
                "context_json": json.dumps(
                    {
                        "AP_Actividad": "Fotografía",
                        "ActividadName": "Fotografo",
                        "IssueResuelto": "Si",
                    }
                ),
            },
            lastrowid=77,
        )
        event = SimpleNamespace(
            context=StatusContext(
                provider_name="botmaker",
                snapshot_at=datetime(2026, 4, 22, 14, 0, 1),
                product=None,
                topic=None,
                subtopic=None,
                quote_external_id="quote-1",
                coverage_external_id="coverage-1",
                quoted_total_amount=Decimal("620.00"),
                quote_description="Seguro AP",
                activity_name="Fotografo",
                completion_message_text="Listo",
                context_json={
                    "ActividadName": "Fotografo",
                    "AP_Actividad": "Fotografía",
                    "IssueResuelto": "Si",
                },
            )
        )

        context_id = self.repository._insert_context(cursor, event, 10, 20)

        self.assertEqual(context_id, 55)
        self.assertEqual(len(cursor.executions), 1)
        self.assertIn("FROM conversation_contexts", cursor.executions[0][0])

    def test_insert_context_persists_when_material_context_changes(self):
        cursor = FakeCursor(
            context_response={
                "id": 55,
                "snapshot_at": datetime(2026, 4, 22, 14, 0, 0),
                "product": None,
                "topic": None,
                "subtopic": None,
                "quote_external_id": None,
                "coverage_external_id": None,
                "quoted_total_amount": None,
                "quote_description": None,
                "activity_name": "Fotografo",
                "completion_message_text": None,
                "context_json": json.dumps({"ActividadName": "Fotografo"}),
            },
            lastrowid=88,
        )
        event = SimpleNamespace(
            context=StatusContext(
                provider_name="botmaker",
                snapshot_at=datetime(2026, 4, 22, 14, 5, 0),
                product=None,
                topic=None,
                subtopic=None,
                quote_external_id="quote-2",
                coverage_external_id=None,
                quoted_total_amount=Decimal("850.00"),
                quote_description="Seguro nuevo",
                activity_name="Fotografo",
                completion_message_text=None,
                context_json={"ActividadName": "Fotografo", "AP_QuoteId": "quote-2"},
            )
        )

        context_id = self.repository._insert_context(cursor, event, 10, 20)

        self.assertEqual(context_id, 88)
        self.assertEqual(len(cursor.executions), 2)
        self.assertIn("INSERT INTO conversation_contexts", cursor.executions[-1][0])


if __name__ == "__main__":
    unittest.main()
