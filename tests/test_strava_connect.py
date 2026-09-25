import importlib.util
import io
import json
import os
import unittest
from unittest import mock

MODULE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "strava-connect.py"
)
_spec = importlib.util.spec_from_file_location("strava_connect", MODULE_PATH)
connect = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(connect)


class FakeResponse:
    def __init__(self, body):
        self._buffer = io.BytesIO(body)

    def read(self, size=-1):
        return self._buffer.read(size)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class EndlessResponse(FakeResponse):
    def __init__(self):
        self.bytes_served = 0

    def read(self, size=-1):
        if size is None or size < 0:
            raise AssertionError("unbounded read of a remote response")
        self.bytes_served += size
        return b"x" * size


class TokenExchangeTest(unittest.TestCase):
    def test_parses_a_normal_token_response(self):
        body = json.dumps({"access_token": "a", "refresh_token": "r", "expires_at": 1}).encode()
        with mock.patch("urllib.request.urlopen", return_value=FakeResponse(body)):
            tokens = connect.exchange_code_for_tokens("id", "secret", "code")
        self.assertEqual(tokens["access_token"], "a")

    def test_an_endless_token_response_is_rejected_with_bounded_memory(self):
        endless = EndlessResponse()
        with mock.patch("urllib.request.urlopen", return_value=endless):
            with self.assertRaises(connect.ResponseTooLarge):
                connect.exchange_code_for_tokens("id", "secret", "code")
        self.assertLessEqual(endless.bytes_served, connect.MAX_TOKEN_RESPONSE_BYTES + 1)


if __name__ == "__main__":
    unittest.main()
