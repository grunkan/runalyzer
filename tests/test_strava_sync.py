import contextlib
import importlib.util
import io
import json
import os
import tempfile
import time
import unittest
from datetime import date, datetime, timedelta
from unittest import mock

MODULE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "strava-sync.py"
)
_spec = importlib.util.spec_from_file_location("strava_sync", MODULE_PATH)
sync = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sync)


class MapActivityTest(unittest.TestCase):
    def test_maps_the_fields_the_widget_reads(self):
        mapped = sync.map_activity({
            "id": 42,
            "name": "Morning Run",
            "start_date_local": "2026-09-14T06:32:11Z",
            "distance": 10500.0,
            "moving_time": 3000,
            "total_elevation_gain": 87.4,
            "average_heartrate": 152.6,
            "max_heartrate": 171.0,
            "suffer_score": 64.0,
            "average_cadence": 86.2,
        })

        self.assertEqual(mapped["id"], 42)
        self.assertEqual(mapped["name"], "Morning Run")
        self.assertEqual(mapped["date"], "2026-09-14")
        self.assertEqual(mapped["time"], "06:32")
        self.assertAlmostEqual(mapped["distanceKm"], 10.5)
        self.assertEqual(mapped["durationSec"], 3000)
        self.assertEqual(mapped["elevationM"], 87)
        self.assertEqual(mapped["avgHr"], 153)
        self.assertEqual(mapped["maxHr"], 171)
        self.assertEqual(mapped["relativeEffort"], 64)
        self.assertAlmostEqual(mapped["avgCadence"], 86.2)

    def test_survives_an_activity_recorded_without_a_heart_rate_monitor(self):
        # Strava omits the heart rate keys entirely rather than nulling them,
        # and they are absent from the published schema, so they can only be
        # read defensively.
        mapped = sync.map_activity({
            "id": 7,
            "start_date_local": "2026-09-14T06:32:11Z",
            "distance": 5000.0,
            "moving_time": 1800,
        })

        self.assertIsNone(mapped["avgHr"])
        self.assertIsNone(mapped["maxHr"])
        self.assertIsNone(mapped["relativeEffort"])
        self.assertIsNone(mapped["avgCadence"])
        self.assertAlmostEqual(mapped["distanceKm"], 5.0)

    def test_date_stays_sortable_iso(self):
        # The widget compares these strings lexicographically to build its
        # rolling windows, so the YYYY-MM-DD shape is load-bearing.
        earlier = sync.map_activity({"start_date_local": "2026-01-09T07:00:00Z"})["date"]
        later = sync.map_activity({"start_date_local": "2026-01-10T07:00:00Z"})["date"]

        self.assertEqual(len(earlier), 10)
        self.assertLess(earlier, later)

    def test_missing_fields_degrade_to_neutral_values(self):
        mapped = sync.map_activity({})

        self.assertEqual(mapped["date"], "")
        self.assertEqual(mapped["time"], "")
        self.assertEqual(mapped["distanceKm"], 0)
        self.assertEqual(mapped["durationSec"], 0)
        self.assertEqual(mapped["elevationM"], 0)
        self.assertIsNone(mapped["avgHr"])
        self.assertIsNone(mapped["maxHr"])
        self.assertIsNone(mapped["relativeEffort"])
        self.assertIsNone(mapped["avgCadence"])


class FetchWindowTest(unittest.TestCase):
    def window_start(self):
        return datetime.fromtimestamp(sync.fetch_window_start_epoch()).date()

    def test_covers_the_widest_window_the_widget_can_ask_for(self):
        today = datetime.now().date()
        self.assertLessEqual(
            self.window_start(), today - timedelta(days=sync.LOOKBACK_DAYS - 1)
        )

    def test_covers_the_start_of_the_current_year(self):
        self.assertLessEqual(self.window_start(), date(datetime.now().year, 1, 1))


class WriteStatusTest(unittest.TestCase):
    def read_written_status(self, *args):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "status.json")
            sync.write_status(path, *args)
            with open(path) as handle:
                return json.load(handle)

    def test_writes_exactly_the_fields_the_widget_reads(self):
        record = self.read_written_status(True, None, "", [{"id": 1}], "2026-09-18T10:00:00Z")

        self.assertEqual(
            set(record),
            {"connected", "updatedAt", "lastAttemptAt", "error", "authHelpText", "activities"},
        )
        self.assertEqual(record["activities"], [{"id": 1}])

    def keep_previous(self, activities):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "status.json")
            sync.write_status(path, True, None, "", activities, "2026-09-18T10:00:00Z")

            previous = sync.load_previous_state(path)
            sync.write_keep_previous(path, "rate_limited", "Slow down.", previous)

            with open(path) as handle:
                return json.load(handle)

    def test_keeps_recent_activities_when_a_sync_fails(self):
        recent = {"id": 7, "date": datetime.now().date().isoformat()}
        record = self.keep_previous([recent])

        self.assertEqual(record["activities"], [recent])
        self.assertEqual(record["updatedAt"], "2026-09-18T10:00:00Z")
        self.assertEqual(record["error"], "rate_limited")

    def test_drops_activities_past_the_cache_limit_when_a_sync_fails(self):
        # Strava's API policy forbids holding their data longer than seven
        # days, and a run of failed syncs must not quietly keep it alive.
        today = datetime.now().date()
        inside = {"id": 1, "date": (today - timedelta(days=6)).isoformat()}
        outside = {"id": 2, "date": (today - timedelta(days=7)).isoformat()}
        undated = {"id": 3}

        record = self.keep_previous([inside, outside, undated])

        self.assertEqual(record["activities"], [inside])


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
    """A body that never ends, and that fails any read without a bound.

    json.load(response) is exactly such a read, which is what made an
    oversized response able to exhaust memory.
    """

    def __init__(self):
        self.bytes_served = 0

    def read(self, size=-1):
        if size is None or size < 0:
            raise AssertionError("unbounded read of a remote response")
        self.bytes_served += size
        return b"x" * size


class ResponseLimitTest(unittest.TestCase):
    def test_parses_a_body_that_exactly_fits(self):
        body = json.dumps([{"id": 1}]).encode()
        self.assertEqual(sync.read_json_limited(FakeResponse(body), len(body)), [{"id": 1}])

    def test_rejects_a_body_one_byte_over(self):
        body = json.dumps([{"id": 1}]).encode()
        with self.assertRaises(sync.ResponseTooLarge):
            sync.read_json_limited(FakeResponse(body), len(body) - 1)

    def test_never_reads_more_than_one_byte_past_the_limit(self):
        endless = EndlessResponse()
        with self.assertRaises(sync.ResponseTooLarge):
            sync.read_json_limited(endless, 1024)
        self.assertLessEqual(endless.bytes_served, 1025)

    def test_an_endless_activities_page_is_rejected_with_bounded_memory(self):
        endless = EndlessResponse()
        with mock.patch("urllib.request.urlopen", return_value=endless):
            with self.assertRaises(sync.ResponseTooLarge):
                sync.fetch_activities_since("token", 0)
        self.assertLessEqual(endless.bytes_served, sync.MAX_ACTIVITIES_RESPONSE_BYTES + 1)

    def test_an_endless_token_response_is_rejected_with_bounded_memory(self):
        endless = EndlessResponse()
        with mock.patch("urllib.request.urlopen", return_value=endless):
            with self.assertRaises(sync.ResponseTooLarge):
                sync.refresh_access_token("id", "secret", "refresh")
        self.assertLessEqual(endless.bytes_served, sync.MAX_TOKEN_RESPONSE_BYTES + 1)

    def test_caps_leave_headroom_above_a_full_activities_page(self):
        # A measured page of real activities came to about 2.2 KB each.
        full_page = 200 * 2248
        self.assertGreater(sync.MAX_ACTIVITIES_RESPONSE_BYTES, 4 * full_page)


class OversizedResponseSyncTest(unittest.TestCase):
    """Runs the whole sync against a server that sends an endless body."""

    def run_sync(self, expires_at):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        state = os.path.join(self.tmp.name, "omarchy", "strava")
        os.makedirs(state)
        self.auth_path = os.path.join(state, "auth.json")
        self.status_path = os.path.join(state, "status.json")
        with open(self.auth_path, "w") as handle:
            json.dump({"clientId": "id", "clientSecret": "secret", "accessToken": "token",
                       "refreshToken": "refresh", "expiresAt": expires_at}, handle)
        self.recent = {"id": 1, "date": datetime.now().date().isoformat()}
        with open(self.status_path, "w") as handle:
            json.dump({"activities": [self.recent], "updatedAt": "earlier"}, handle)
        with open(self.auth_path, "rb") as handle:
            self.auth_before = handle.read()

        with mock.patch.dict(os.environ, {"XDG_STATE_HOME": self.tmp.name}), \
                mock.patch("urllib.request.urlopen", return_value=EndlessResponse()), \
                contextlib.redirect_stderr(io.StringIO()):
            result = sync.main()

        with open(self.status_path) as handle:
            self.status = json.load(handle)
        with open(self.auth_path, "rb") as handle:
            self.auth_after = handle.read()
        return result

    def test_oversized_activities_keep_the_previous_data(self):
        self.assertEqual(self.run_sync(expires_at=time.time() + 3600), 0)
        self.assertEqual(self.status["error"], "fetch_failed")
        self.assertIn("large", self.status["authHelpText"])
        self.assertEqual(self.status["activities"], [self.recent])
        self.assertTrue(self.status["connected"])

    def test_oversized_token_refresh_leaves_credentials_untouched(self):
        # An expired token forces a refresh first; the rejected response
        # must not be written over the stored credentials.
        self.assertEqual(self.run_sync(expires_at=0), 0)
        self.assertEqual(self.status["error"], "fetch_failed")
        self.assertEqual(self.auth_after, self.auth_before)


if __name__ == "__main__":
    unittest.main()
