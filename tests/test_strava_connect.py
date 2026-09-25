import http.client
import http.server
import importlib.util
import io
import json
import os
import socket
import threading
import time
import urllib.error
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
        with mock.patch.object(connect, "open_url", return_value=FakeResponse(body)):
            tokens = connect.exchange_code_for_tokens("id", "secret", "code")
        self.assertEqual(tokens["access_token"], "a")

    def test_an_endless_token_response_is_rejected_with_bounded_memory(self):
        endless = EndlessResponse()
        with mock.patch.object(connect, "open_url", return_value=endless):
            with self.assertRaises(connect.ResponseTooLarge):
                connect.exchange_code_for_tokens("id", "secret", "code")
        self.assertLessEqual(endless.bytes_served, connect.MAX_TOKEN_RESPONSE_BYTES + 1)


class ListenerTest(unittest.TestCase):
    PORT = 18911

    def start(self, timeout):
        self.outcome = {}

        def run():
            started = time.monotonic()
            self.outcome["result"] = connect.run_oauth_listener(self.PORT, timeout, "the-state")
            self.outcome["elapsed"] = time.monotonic() - started

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()
        time.sleep(0.3)

    def request(self, host, path):
        conn = http.client.HTTPConnection("localhost", self.PORT, timeout=5)
        conn.putrequest("GET", path, skip_host=True)
        conn.putheader("Host", host)
        conn.endheaders()
        status = conn.getresponse().status
        conn.close()
        return status

    def test_a_silent_connection_no_longer_holds_the_listener(self):
        # Before, a 5 s listener was still blocked after 20 s.
        with mock.patch.object(connect, "CALLBACK_READ_TIMEOUT_SEC", 1):
            self.start(timeout=2)
            silent = socket.create_connection(("localhost", self.PORT))
            self.thread.join(8)
            silent.close()
        self.assertFalse(self.thread.is_alive())
        self.assertEqual(self.outcome["result"], (None, "timeout"))
        self.assertLess(self.outcome["elapsed"], 5)

    def test_a_request_naming_another_host_is_refused(self):
        # What a DNS-rebinding page would send: our port, its own host name.
        self.start(timeout=5)
        path = "/strava-callback?state=the-state&code=stolen"
        self.assertEqual(self.request("evil.example:%d" % self.PORT, path), 403)
        self.assertEqual(self.request("localhost:%d" % self.PORT, path.replace("stolen", "real")), 200)
        self.thread.join(5)
        self.assertEqual(self.outcome["result"], ("real", None))


class ExchangeRedirectTest(unittest.TestCase):
    def test_the_token_exchange_refuses_a_redirect(self):
        hits = []

        class Target(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append(self.path)
                self.send_response(200)
                self.end_headers()

            do_POST = do_GET

            def log_message(self, *args):
                pass

        target = http.server.HTTPServer(("127.0.0.1", 0), Target)
        threading.Thread(target=target.serve_forever, daemon=True).start()
        self.addCleanup(target.server_close)
        self.addCleanup(target.shutdown)

        class Redirect(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.send_response(307)
                self.send_header("Location", "http://localhost:%d/x" % target.server_address[1])
                self.end_headers()

            def log_message(self, *args):
                pass

        redirector = http.server.HTTPServer(("127.0.0.1", 0), Redirect)
        threading.Thread(target=redirector.serve_forever, daemon=True).start()
        self.addCleanup(redirector.server_close)
        self.addCleanup(redirector.shutdown)

        with mock.patch.object(connect, "TOKEN_URL", "http://127.0.0.1:%d/token" % redirector.server_address[1]):
            with self.assertRaises(urllib.error.HTTPError) as caught:
                connect.exchange_code_for_tokens("id", "secret", "code")
        caught.exception.close()
        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()
