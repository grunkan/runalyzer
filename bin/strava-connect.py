#!/usr/bin/env python3
"""One-time OAuth2 connect flow for the Strava API.

Opens the Strava authorize page in the default browser, catches the
redirect on a short-lived local HTTP listener, exchanges the returned
code for an access/refresh token pair, and writes them to auth.json.

This process only runs for the few seconds the connect flow takes -
it is not a persistent webhook receiver.
"""

import argparse
import http.server
import json
import os
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


def build_authorize_url(client_id, redirect_uri, scope):
    query = urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "approval_prompt": "auto",
        "scope": scope,
    })
    return AUTHORIZE_URL + "?" + query


class _CallbackResult:
    code = None
    error = None


def _make_handler(result):
    class CallbackHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urllib.parse.urlsplit(self.path)
            params = urllib.parse.parse_qs(parsed.query)
            if "code" in params:
                result.code = params["code"][0]
                body = "<html><body>Done! You can close this tab now.</body></html>"
            else:
                result.error = (params.get("error") or ["unknown_error"])[0]
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


def run_oauth_listener(port, timeout):
    result = _CallbackResult()
    handler = _make_handler(result)
    httpd = http.server.HTTPServer(("127.0.0.1", port), handler)
    httpd.timeout = timeout
    httpd.handle_request()
    httpd.server_close()
    if result.code is None and result.error is None:
        return None, "timeout"
    return result.code, result.error


def exchange_code_for_tokens(client_id, client_secret, code):
    body = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "code": code,
        "grant_type": "authorization_code",
    }).encode("utf-8")
    request = urllib.request.Request(TOKEN_URL, data=body, method="POST")
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)


def write_auth_file(state_dir, record):
    os.makedirs(state_dir, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=state_dir, prefix=".auth-")
    try:
        os.chmod(tmp_path, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(record, handle)
        os.replace(tmp_path, os.path.join(state_dir, "auth.json"))
    except Exception:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise


def open_browser(url):
    print(url, file=sys.stderr)
    try:
        import webbrowser
        webbrowser.open(url)
    except Exception:
        pass


def main():
    args = parse_args()
    client_secret = os.environ.get("STRAVA_CLIENT_SECRET", "").strip()
    if not client_secret:
        print("STRAVA_CLIENT_SECRET is missing from the environment", file=sys.stderr)
        return 1

    redirect_uri = "http://localhost:%d/strava-callback" % args.port
    authorize_url = build_authorize_url(args.client_id, redirect_uri, args.scope)
    open_browser(authorize_url)

    code, error = run_oauth_listener(args.port, args.timeout)
    if error == "timeout":
        print("No login within the time limit", file=sys.stderr)
        return 1
    if error:
        print("Strava denied the connection: %s" % error, file=sys.stderr)
        return 1
    if not code:
        print("Did not receive a code back from Strava", file=sys.stderr)
        return 1

    try:
        tokens = exchange_code_for_tokens(args.client_id, client_secret, code)
    except urllib.error.HTTPError as err:
        print("Could not fetch token from Strava: %s" % err, file=sys.stderr)
        return 1
    except urllib.error.URLError as err:
        print("Could not reach Strava: %s" % err, file=sys.stderr)
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
    write_auth_file(args.state_dir, record)
    print("Connected to Strava")
    return 0


if __name__ == "__main__":
    sys.exit(main())
