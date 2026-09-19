#!/usr/bin/env python3
"""Fetches the latest Strava runs and writes status.json for the widget.

Reads credentials from auth.json, refreshes the access token when needed
(persisting Strava's rotated refresh token), fetches recent activities,
filters to runs, and writes the last 5 to status.json. Always writes
valid JSON, even on failure, so the widget can degrade gracefully.
"""

import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta

TOKEN_URL = "https://www.strava.com/oauth/token"
ACTIVITIES_URL = "https://www.strava.com/api/v3/athlete/activities"
TOKEN_EXPIRY_MARGIN_SEC = 300


def state_dir():
    return os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
        "omarchy", "strava",
    )


def atomic_write_json(path, record, mode=None):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    try:
        if mode is not None:
            os.chmod(tmp_path, mode)
        with os.fdopen(fd, "w") as handle:
            json.dump(record, handle)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load_auth(path):
    with open(path, "r") as handle:
        return json.load(handle)


def load_previous_status(path):
    try:
        with open(path, "r") as handle:
            return json.load(handle)
    except Exception:
        return None


def empty_summary():
    return {"count": 0, "distanceKm": 0, "durationSec": 0, "elevationM": 0}


def empty_weekly_summary():
    return {"count": 0, "distanceKm": 0, "avgKmPerWeek": 0}


def parse_start(start_date_local):
    if not start_date_local:
        return None
    try:
        return datetime.strptime(start_date_local[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None


def within_last_days(start_date_local, days):
    # Calendar-day window: today plus the (days - 1) preceding calendar
    # days, matching how Strava/Garmin show "last 7 days" (e.g. today the
    # 16th covers the 10th-16th) rather than a rolling 24*days-hour window.
    start = parse_start(start_date_local)
    if not start:
        return False
    return start.date() >= datetime.now().date() - timedelta(days=days - 1)


def within_current_year(runs):
    year = datetime.now().year
    result = []
    for a in runs:
        start = parse_start(a.get("start_date_local"))
        if start and start.year == year:
            result.append(a)
    return result


def summarize(runs):
    return {
        "count": len(runs),
        "distanceKm": sum((a.get("distance") or 0) for a in runs) / 1000.0,
        "durationSec": sum((a.get("moving_time") or 0) for a in runs),
        "elevationM": round(sum((a.get("total_elevation_gain") or 0) for a in runs)),
    }


def summarize_avg_per_week(runs, weeks_divisor):
    distance_km = sum((a.get("distance") or 0) for a in runs) / 1000.0
    weeks_divisor = max(1, weeks_divisor)
    return {
        "count": len(runs),
        "distanceKm": distance_km,
        "avgKmPerWeek": distance_km / weeks_divisor,
    }


def elapsed_weeks_this_year():
    return max(1, datetime.now().date().isocalendar()[1])


def fetch_window_start_epoch():
    today = datetime.now().date()
    year_start = date(today.year, 1, 1)
    six_week_start = today - timedelta(days=41)
    window_start = min(year_start, six_week_start)
    return int(datetime.combine(window_start, datetime.min.time()).timestamp())


def write_status(status_path, connected, error, auth_help_text, activities, updated_at,
                  summary=None, summary_weeks=None, summary_year=None):
    record = {
        "connected": connected,
        "updatedAt": updated_at,
        "lastAttemptAt": now_iso(),
        "error": error,
        "authHelpText": auth_help_text,
        "activities": activities,
        "summary": summary if summary is not None else empty_summary(),
        "summaryWeeks6": summary_weeks if summary_weeks is not None else empty_weekly_summary(),
        "summaryYear": summary_year if summary_year is not None else empty_weekly_summary(),
    }
    atomic_write_json(status_path, record)


def load_previous_state(status_path):
    previous = load_previous_status(status_path) or {}
    return {
        "activities": previous.get("activities") or [],
        "updatedAt": previous.get("updatedAt") or "",
        "summary": previous.get("summary") or empty_summary(),
        "summaryWeeks6": previous.get("summaryWeeks6") or empty_weekly_summary(),
        "summaryYear": previous.get("summaryYear") or empty_weekly_summary(),
    }


def write_keep_previous(status_path, error, help_text, previous_state):
    write_status(
        status_path, True, error, help_text,
        previous_state["activities"], previous_state["updatedAt"],
        previous_state["summary"], previous_state["summaryWeeks6"], previous_state["summaryYear"],
    )


def write_auth_expired(status_path):
    write_status(
        status_path, False, "auth_expired",
        "Your Strava connection has expired. Please reconnect.", [], "",
    )


def refresh_access_token(client_id, client_secret, refresh_token):
    body = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    }).encode("utf-8")
    request = urllib.request.Request(TOKEN_URL, data=body, method="POST")
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)


def refresh_or_expire(client_id, client_secret, refresh_token, auth, auth_path):
    try:
        tokens = refresh_access_token(client_id, client_secret, refresh_token)
    except urllib.error.HTTPError:
        return None
    access_token = tokens.get("access_token")
    auth["accessToken"] = access_token
    auth["refreshToken"] = tokens.get("refresh_token")
    auth["expiresAt"] = tokens.get("expires_at")
    atomic_write_json(auth_path, auth, mode=0o600)
    return access_token


MAX_ACTIVITY_PAGES = 10


def fetch_activities_since(access_token, after_epoch, per_page=200):
    all_activities = []
    for page in range(1, MAX_ACTIVITY_PAGES + 1):
        query = urllib.parse.urlencode({"per_page": per_page, "page": page, "after": after_epoch})
        request = urllib.request.Request(
            ACTIVITIES_URL + "?" + query,
            headers={"Authorization": "Bearer " + access_token},
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            batch = json.load(response)
        all_activities.extend(batch)
        if len(batch) < per_page:
            break
    return all_activities


def map_activity(activity):
    start = activity.get("start_date_local") or ""
    date, _, rest = start.partition("T")
    time_part = rest[:5] if rest else ""
    avg_hr = activity.get("average_heartrate")
    return {
        "id": activity.get("id"),
        "name": activity.get("name"),
        "date": date,
        "time": time_part,
        "distanceKm": (activity.get("distance") or 0) / 1000.0,
        "durationSec": activity.get("moving_time") or 0,
        "elevationM": round(activity.get("total_elevation_gain") or 0),
        "avgHr": round(avg_hr) if avg_hr else None,
    }


def main():
    dir_path = state_dir()
    auth_path = os.path.join(dir_path, "auth.json")
    status_path = os.path.join(dir_path, "status.json")

    not_connected_text = "Connect your Strava account to see your latest runs."

    try:
        auth = load_auth(auth_path)
    except Exception:
        write_status(status_path, False, "not_connected", not_connected_text, [], "")
        return 0

    previous_state = load_previous_state(status_path)

    try:
        client_id = auth["clientId"]
        client_secret = auth["clientSecret"]
        access_token = auth.get("accessToken")
        refresh_token = auth["refreshToken"]
        expires_at = auth.get("expiresAt") or 0

        if not access_token or expires_at - time.time() < TOKEN_EXPIRY_MARGIN_SEC:
            access_token = refresh_or_expire(client_id, client_secret, refresh_token, auth, auth_path)
            if access_token is None:
                write_auth_expired(status_path)
                return 0

        after_epoch = fetch_window_start_epoch()

        try:
            activities = fetch_activities_since(access_token, after_epoch)
        except urllib.error.HTTPError as err:
            if err.code == 401:
                access_token = refresh_or_expire(client_id, client_secret, refresh_token, auth, auth_path)
                if access_token is None:
                    write_auth_expired(status_path)
                    return 0
                try:
                    activities = fetch_activities_since(access_token, after_epoch)
                except urllib.error.HTTPError:
                    write_auth_expired(status_path)
                    return 0
            elif err.code == 429:
                write_keep_previous(
                    status_path, "rate_limited",
                    "Strava has rate-limited requests. Retrying automatically.",
                    previous_state,
                )
                return 0
            else:
                write_keep_previous(
                    status_path, "fetch_failed", "Couldn't fetch activities right now.", previous_state,
                )
                return 0
        except urllib.error.URLError:
            write_keep_previous(
                status_path, "fetch_failed", "Couldn't fetch activities right now.", previous_state,
            )
            return 0

        runs = [a for a in activities if a.get("type") == "Run"]
        runs.sort(key=lambda a: a.get("start_date_local") or "", reverse=True)
        mapped = [map_activity(a) for a in runs[:5]]
        week_runs = [a for a in runs if within_last_days(a.get("start_date_local"), 7)]
        six_week_runs = [a for a in runs if within_last_days(a.get("start_date_local"), 42)]
        year_runs = within_current_year(runs)

        write_status(
            status_path, True, None, "", mapped, now_iso(),
            summarize(week_runs),
            summarize_avg_per_week(six_week_runs, 6),
            summarize_avg_per_week(year_runs, elapsed_weeks_this_year()),
        )
        return 0
    except Exception as exc:
        write_keep_previous(
            status_path, "fetch_failed", "Couldn't fetch activities right now.", previous_state,
        )
        print("strava-sync error: %s" % exc, file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
