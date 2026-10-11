"""Reset regression tests; all credentials, network and probes are replaced.

Set CLAUDIUS_TEST_BACKEND to check a prepared or installed backend as well.
"""

import contextlib
import io
import json
import os
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, patch


TARGET = Path(os.environ.get(
    "CLAUDIUS_TEST_BACKEND", Path(__file__).resolve().parents[1] / "claude-usage"))
backend = {"__name__": "claudius_under_test", "__file__": str(TARGET)}
exec(compile(TARGET.read_text(), str(TARGET), "exec"), backend)
NOW = datetime(2026, 10, 11, 22, 31, tzinfo=timezone.utc)


def usage(seconds, percent=0):
    return {
        "five_hour": {
            "utilization": percent,
            "resets_at": (NOW + timedelta(seconds=seconds)).isoformat(),
        },
        "seven_day": {
            "utilization": 49,
            "resets_at": (NOW + timedelta(days=1)).isoformat(),
        },
    }


class AnchorTests(unittest.TestCase):
    def setUp(self):
        self.now = NOW
        self.state = {}
        self.raw = usage(-60, 100)
        self.probe = Mock(return_value=(True, "ok"))
        stubs = patch.dict(
            backend,
            now_utc=lambda: self.now,
            load_state=lambda: dict(self.state),
            save_state=self.save,
            log_anchor=lambda _: None,
            get_usage=lambda **_: (self.raw, "ok", dict(self.state)),
            run_claude_probe=self.probe,
        )
        stubs.start()
        self.addCleanup(stubs.stop)

    def save(self, state):
        self.state = dict(state)

    def anchor(self, force=False):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as stop:
            backend["run_anchor"](force, True)
        return stop.exception.code, json.loads(out.getvalue())

    def test_open_limited_window_skips(self):
        self.raw = usage(3600, 100)
        self.assertEqual(self.anchor()[0], 3)
        self.probe.assert_not_called()

    def test_open_zero_percent_window_skips(self):
        self.raw = usage(18000, 0)
        self.assertEqual(self.anchor()[0], 3)
        self.probe.assert_not_called()

    def test_reset_with_stale_100_percent_sends(self):
        self.assertEqual(self.anchor()[0], 0)
        self.probe.assert_called_once()

    def test_missing_window_sends(self):
        self.raw = {}
        self.assertEqual(self.anchor()[0], 0)

    def test_no_usage_fails_without_probe(self):
        self.raw = None
        self.assertEqual(self.anchor()[0], 2)
        self.probe.assert_not_called()

    def test_success_blocks_repeated_probe(self):
        self.assertEqual(self.anchor()[0], 0)
        self.now += timedelta(minutes=2)
        self.assertEqual(self.anchor()[0], 4)
        self.probe.assert_called_once()

    def test_legacy_guard_expires(self):
        self.state["last_anchor_attempt"] = NOW.timestamp() - 1801
        self.assertEqual(self.anchor()[0], 0)

    def test_legacy_guard_still_blocks_before_30_minutes(self):
        self.state["last_anchor_attempt"] = NOW.timestamp() - 120
        self.assertEqual(self.anchor()[0], 4)
        self.probe.assert_not_called()

    def test_failure_allows_app_two_minute_retry(self):
        self.probe.return_value = (False, "temporary network error")
        self.assertEqual(self.anchor()[0], 5)
        self.now += timedelta(minutes=2)
        self.probe.return_value = (True, "ok")
        self.assertEqual(self.anchor()[0], 0)
        self.assertEqual(self.probe.call_count, 2)

    def test_failure_still_guards_rapid_retries(self):
        self.probe.return_value = (False, "temporary network error")
        self.assertEqual(self.anchor()[0], 5)
        self.now += timedelta(seconds=119)
        self.assertEqual(self.anchor()[0], 4)
        self.probe.assert_called_once()

    def test_failure_guard_starts_when_request_finishes(self):
        def slow_failure():
            self.now += timedelta(minutes=3)
            return False, "probe timed out"

        self.probe.side_effect = slow_failure
        self.assertEqual(self.anchor()[0], 5)
        self.assertEqual(self.anchor()[0], 4)
        self.probe.assert_called_once()

    def test_successful_retry_restores_30_minute_guard(self):
        self.probe.return_value = (False, "temporary network error")
        self.assertEqual(self.anchor()[0], 5)
        self.now += timedelta(minutes=2)
        self.probe.return_value = (True, "ok")
        self.assertEqual(self.anchor()[0], 0)
        self.now += timedelta(minutes=2)
        self.assertEqual(self.anchor()[0], 4)
        self.assertEqual(self.probe.call_count, 2)

    def test_failure_preserves_other_state_updates_during_probe(self):
        def failure_after_update():
            self.state["token_exp"] = 12345
            return False, "temporary network error"

        self.probe.side_effect = failure_after_update
        self.assertEqual(self.anchor()[0], 5)
        self.assertEqual(self.state["token_exp"], 12345)

    def test_forced_request_bypasses_open_window(self):
        self.raw = usage(100, 100)
        self.assertEqual(self.anchor(force=True)[0], 0)

    def test_report_preserves_limited_window_for_app(self):
        windows, available = backend["build_report"](usage(100, 100), 100, None)
        self.assertFalse(available)
        self.assertTrue(windows[0]["blocked"])
        self.assertEqual(windows[0]["resets_in_seconds"], 100)

    def test_report_floors_lapsed_window(self):
        windows, _ = backend["build_report"](usage(-60, 100), 100, None)
        self.assertEqual(windows[0]["resets_in_seconds"], 0)


if __name__ == "__main__":
    unittest.main()
