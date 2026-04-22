import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from handlers.base import handle_webhook
from utils.exceptions import ValidationError


class HandlerLoggingTest(unittest.TestCase):
    def test_validation_errors_log_message_and_payload_keys(self):
        event = {
            "body": json.dumps(
                {
                    "customerId": "customer-123",
                    "date": "2026-04-22T14:25:30.044778+00:00",
                    "message": "hola",
                }
            ),
            "requestContext": {"requestId": "ea90ff09-bdac-4399-afb5-f2d73780e5a9"},
        }

        with (
            patch(
                "handlers.base.service.process",
                side_effect=ValidationError("Incoming payload is missing sessionId"),
            ),
            patch("handlers.base.logger.warning") as warning_mock,
        ):
            response = handle_webhook("incoming", event)

        warning_mock.assert_called_once()
        _, kwargs = warning_mock.call_args
        self.assertEqual(kwargs["extra"]["error_code"], "validation_error")
        self.assertEqual(
            kwargs["extra"]["error_message"],
            "Incoming payload is missing sessionId",
        )
        self.assertEqual(
            kwargs["extra"]["payload_keys"],
            ["customerId", "date", "message"],
        )
        self.assertEqual(
            kwargs["extra"]["request_id"],
            "ea90ff09-bdac-4399-afb5-f2d73780e5a9",
        )

        body = json.loads(response["body"])
        self.assertEqual(response["statusCode"], 400)
        self.assertEqual(body["error"]["code"], "validation_error")
        self.assertEqual(
            body["error"]["message"],
            "Incoming payload is missing sessionId",
        )


if __name__ == "__main__":
    unittest.main()
