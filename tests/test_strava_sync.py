import importlib.util
import json
import os
import tempfile
import unittest
from datetime import date, datetime, timedelta

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

    def test_keeps_previous_activities_when_a_sync_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "status.json")
            sync.write_status(path, True, None, "", [{"id": 7}], "2026-09-18T10:00:00Z")

            previous = sync.load_previous_state(path)
            sync.write_keep_previous(path, "rate_limited", "Slow down.", previous)

            with open(path) as handle:
                record = json.load(handle)

        self.assertEqual(record["activities"], [{"id": 7}])
        self.assertEqual(record["updatedAt"], "2026-09-18T10:00:00Z")
        self.assertEqual(record["error"], "rate_limited")


if __name__ == "__main__":
    unittest.main()
