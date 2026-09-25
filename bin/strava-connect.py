#!/usr/bin/env python3
"""One-time OAuth2 connect flow for the Strava API.

Opens the Strava authorize page in the default browser, catches the
redirect on a short-lived local HTTP listener, exchanges the returned
code for an access/refresh token pair, and writes them to auth.json.

This process only runs for the few seconds the connect flow takes -
it is not a persistent webhook receiver.
"""

import argparse
import hmac
import http.server
import json
import os
import secrets
import signal
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

AUTHORIZE_URL = "https://www.strava.com/oauth/authorize"
TOKEN_URL = "https://www.strava.com/oauth/token"


def parse_args():
    parser = argparse.ArgumentParser(description="Connect this plugin to the Strava API")
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--port", type=int, default=8737)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--scope", default="activity:read_all")
    default_state_dir = os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
        "omarchy", "strava",
    )
    parser.add_argument("--state-dir", default=default_state_dir)
    return parser.parse_args()


def build_authorize_url(client_id, redirect_uri, scope, state):
    query = urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "approval_prompt": "auto",
        "scope": scope,
        "state": state,
    })
    return AUTHORIZE_URL + "?" + query


class _CallbackResult:
    code = None
    error = None


CALLBACK_READ_TIMEOUT_SEC = 10


def _make_handler(result, expected_state):
    class CallbackHandler(http.server.BaseHTTPRequestHandler):
        # Without this, a connection that never sends a request blocks the
        # single-threaded listener past its own deadline.
        timeout = CALLBACK_READ_TIMEOUT_SEC

        def _host_is_loopback(self):
            # Binding to loopback does not stop a web page reaching us through
            # DNS rebinding, but such a request still carries the page's own
            # host name, so anything not naming loopback is refused.
            port = self.server.server_address[1]
            allowed = {"localhost:%d" % port, "127.0.0.1:%d" % port, "[::1]:%d" % port}
            return (self.headers.get("Host") or "").lower() in allowed

        def do_GET(self):
            if not self._host_is_loopback():
                self.send_error(403)
                return
            parsed = urllib.parse.urlsplit(self.path)
            params = urllib.parse.parse_qs(parsed.query)
            state = (params.get("state") or [""])[0]

            # Ignore any request that doesn't carry our exact state token -
            # this is a loopback HTTP listener on a fixed port, so anything
            # else running locally (e.g. a browser tab) could otherwise race
            # the real Strava redirect and get its own code accepted instead.
            if hmac.compare_digest(state, expected_state):
                if "code" in params:
                    result.code = params["code"][0]
                    body = "<html><body>Done! You can close this tab now.</body></html>"
                else:
                    result.error = (params.get("error") or ["unknown_error"])[0]
                    body = "<html><body>Connection failed. You can close this tab now.</body></html>"
            else:
                body = "<html><body>Connection failed. You can close this tab now.</body></html>"

            encoded = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, format, *args):
            pass

    return CallbackHandler


class _LocalhostServer(http.server.HTTPServer):
    # The redirect Strava sends the browser to says "localhost", which may
    # resolve to ::1 before 127.0.0.1. Binding only the IPv4 loopback would
    # then leave the browser unable to reach us at all.
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        http.server.HTTPServer.server_bind(self)


def _listen(port, handler):
    try:
        return _LocalhostServer(("::1", port), handler)
    except OSError:
        # No usable IPv6 loopback on this host.
        return http.server.HTTPServer(("127.0.0.1", port), handler)


def run_oauth_listener(port, timeout, expected_state):
    result = _CallbackResult()
    handler = _make_handler(result, expected_state)
    try:
        httpd = _listen(port, handler)
    except OSError as err:
        return None, "port_busy: %s" % err
    deadline = time.time() + timeout
    while result.code is None and result.error is None:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        httpd.timeout = remaining
        httpd.handle_request()
    httpd.server_close()
    if result.code is None and result.error is None:
        return None, "timeout"
    return result.code, result.error


# Covers the whole connect run: the login window plus the token exchange. A
# socket timeout only bounds each read, so a slow trickle of headers or body
# could otherwise hold the process open indefinitely.
EXCHANGE_DEADLINE_SEC = 30

MAX_MESSAGE_CHARS = 300


class DeadlineExceeded(BaseException):
    pass


def _deadline_reached(signum, frame):
    raise DeadlineExceeded()


class alarm_deferred:
    """Holds SIGALRM back while the new credentials are written."""

    def __enter__(self):
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})

    def __exit__(self, *exc):
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
        return False


def report(message):
    print(str(message)[:MAX_MESSAGE_CHARS], file=sys.stderr)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # Strava's token endpoint does not redirect; refusing redirects keeps the
    # client secret in the request body from being replayed elsewhere.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def open_url(request, timeout=15):
    return _OPENER.open(request, timeout=timeout)


def ensure_private_dir(directory):
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    if os.stat(directory).st_mode & 0o077:
        raise OSError("could not make %s private to this user" % directory)


# A token response is a few hundred bytes, or a couple of kilobytes with the
# athlete summary. Capping the body before parsing keeps an oversized or
# malformed response from being read into memory whole.
MAX_TOKEN_RESPONSE_BYTES = 64 * 1024


class ResponseTooLarge(Exception):
    pass


def read_json_limited(response, limit):
    payload = response.read(limit + 1)
    if len(payload) > limit:
        raise ResponseTooLarge("response body exceeds %d bytes" % limit)
    return json.loads(payload)


def exchange_code_for_tokens(client_id, client_secret, code):
    body = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "code": code,
        "grant_type": "authorization_code",
    }).encode("utf-8")
    request = urllib.request.Request(TOKEN_URL, data=body, method="POST")
    with open_url(request) as response:
        return read_json_limited(response, MAX_TOKEN_RESPONSE_BYTES)


def write_auth_file(state_dir, record):
    ensure_private_dir(state_dir)
    fd, tmp_path = tempfile.mkstemp(dir=state_dir, prefix=".auth-")
    try:
        os.chmod(tmp_path, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(record, handle)
        os.replace(tmp_path, os.path.join(state_dir, "auth.json"))
    except BaseException:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise


def open_browser(url):
    # stdout, so that stderr carries only the error the widget shows.
    print(url)
    try:
        import webbrowser
        webbrowser.open(url)
    except Exception:
        pass


def read_client_secret():
    # Prefer stdin over an environment variable - env vars are readable by
    # any other process running as the same user (e.g. via /proc/PID/environ)
    # for the lifetime of this process, while a pipe write is a one-shot
    # transfer. STRAVA_CLIENT_SECRET is kept as a fallback for manual/dev use.
    env_secret = os.environ.get("STRAVA_CLIENT_SECRET", "").strip()
    if env_secret:
        return env_secret
    try:
        return sys.stdin.readline().strip()
    except Exception:
        return ""


def connect(args):
    client_secret = read_client_secret()
    if not client_secret:
        report("No Strava client secret was provided on stdin")
        return 1

    state = secrets.token_urlsafe(24)
    redirect_uri = "http://localhost:%d/strava-callback" % args.port
    authorize_url = build_authorize_url(args.client_id, redirect_uri, args.scope, state)
    open_browser(authorize_url)

    code, error = run_oauth_listener(args.port, args.timeout, state)
    if error and error.startswith("port_busy"):
        report("Port %d is already in use, so the Strava login could not be "
               "received. Close whatever is using it, or pass --port." % args.port)
        return 1
    if error == "timeout":
        report("No login within the time limit")
        return 1
    if error:
        report("Strava denied the connection: %s" % error)
        return 1
    if not code:
        report("Did not receive a code back from Strava")
        return 1

    try:
        tokens = exchange_code_for_tokens(args.client_id, client_secret, code)
    except urllib.error.HTTPError as err:
        report("Could not fetch token from Strava: %s" % err)
        return 1
    except urllib.error.URLError as err:
        report("Could not reach Strava: %s" % err)
        return 1
    except ResponseTooLarge:
        report("Strava sent an unexpectedly large response; nothing was saved")
        return 1

    record = {
        "clientId": args.client_id,
        "clientSecret": client_secret,
        "accessToken": tokens.get("access_token"),
        "refreshToken": tokens.get("refresh_token"),
        "expiresAt": tokens.get("expires_at"),
        "athleteId": (tokens.get("athlete") or {}).get("id"),
        "connectedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    with alarm_deferred():
        write_auth_file(args.state_dir, record)
        # Saved: stop the clock and drop an alarm that may already be
        # pending, so it cannot fire after the credentials are in place.
        signal.alarm(0)
        if signal.SIGALRM in signal.sigpending():
            signal.sigtimedwait({signal.SIGALRM}, 0)
    print("Connected to Strava")
    return 0


def main():
    args = parse_args()
    previous_handler = signal.signal(signal.SIGALRM, _deadline_reached)
    signal.alarm(args.timeout + EXCHANGE_DEADLINE_SEC)
    try:
        return connect(args)
    except DeadlineExceeded:
        report("Connecting to Strava took too long; nothing was saved")
        return 1
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous_handler)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        report("strava-connect error: %s" % exc)
        sys.exit(1)
