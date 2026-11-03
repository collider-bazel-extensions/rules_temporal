"""Unit tests for the launcher's readiness timeouts (#10). No server needed."""

import importlib.util
import os
import subprocess
import unittest
from unittest import mock


def _load_launcher():
    root = os.environ.get("TEST_SRCDIR") or os.environ["RUNFILES_DIR"]
    ws = os.environ.get("TEST_WORKSPACE", "_main")
    path = os.path.join(root, ws, "private", "launcher.py")
    spec = importlib.util.spec_from_file_location("launcher", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


L = _load_launcher()


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, s):
        self.now += s


class ReadyTimeoutTest(unittest.TestCase):
    def test_missing_or_empty_keeps_default(self):
        self.assertEqual(L._ready_timeout({}, "worker_ready_timeout"), 30.0)
        self.assertEqual(L._ready_timeout({"worker_ready_timeout": ""}, "worker_ready_timeout"), 30.0)
        self.assertEqual(L._ready_timeout({"worker_ready_timeout": "  "}, "worker_ready_timeout"), 30.0)

    def test_parses(self):
        for raw, want in [("180", 180.0), (2.5, 2.5), (7, 7.0), (" 45 ", 45.0)]:
            self.assertEqual(L._ready_timeout({"k": raw}, "k"), want)

    def test_refuses(self):
        for raw in ["0", "-3", "abc", "60s", "nan", "inf"]:
            with self.assertRaises(ValueError) as cm:
                L._ready_timeout({"server_ready_timeout": raw}, "server_ready_timeout")
            self.assertIn("server_ready_timeout", str(cm.exception))


class WaitWorkerReadyTest(unittest.TestCase):
    def _run_no_pollers(self, *a, **kw):
        return subprocess.CompletedProcess(a, 0, stdout=b'{"pollers": []}', stderr=b"")

    def test_times_out_with_configured_value(self):
        clock = FakeClock()
        with mock.patch.object(L.time, "monotonic", clock.monotonic), \
             mock.patch.object(L.time, "sleep", clock.sleep), \
             mock.patch.object(L.subprocess, "run", self._run_no_pollers):
            with self.assertRaises(TimeoutError) as cm:
                L._wait_worker_ready("temporal", "addr", "ns", "onboarding", timeout=3.0)
        self.assertIn("Worker not ready within 3.0s", str(cm.exception))
        self.assertIn("task_queue='onboarding'", str(cm.exception))
        self.assertGreaterEqual(clock.now, 3.0)
        self.assertLess(clock.now, 4.0)

    def test_returns_early_when_worker_exits(self):
        clock = FakeClock()
        proc = mock.Mock()
        proc.poll.return_value = 1
        with mock.patch.object(L.time, "monotonic", clock.monotonic), \
             mock.patch.object(L.time, "sleep", clock.sleep), \
             mock.patch.object(L.subprocess, "run", self._run_no_pollers):
            self.assertEqual(
                L._wait_worker_ready("temporal", "addr", "ns", "q", timeout=600.0, proc=proc), [])
        self.assertEqual(clock.now, 0.0)


class MainTestPassesTimeoutsTest(unittest.TestCase):
    def _main_test(self, manifest):
        seen = {}

        class Stop(Exception):
            pass

        def fake_start_server(*a, **kw):
            seen["server"] = kw.get("ready_timeout")
            return mock.Mock(), "127.0.0.1:1"

        def fake_wait_worker(*a, **kw):
            seen["worker"] = kw.get("timeout")
            raise Stop()

        m = {"temporal_bin": "t", "worker_binary": "w", "task_queue": "q", **manifest}
        with mock.patch.object(L, "_find_runfile", lambda p, ws="": p), \
             mock.patch.object(L, "_ensure_executable", lambda p: None), \
             mock.patch.object(L, "_start_server", fake_start_server), \
             mock.patch.object(L, "_wait_worker_ready", fake_wait_worker), \
             mock.patch.object(L.subprocess, "Popen", mock.Mock()), \
             mock.patch.object(L.atexit, "register", lambda f: None):
            with self.assertRaises(Stop):
                L.main_test(m, "_main")
        return seen

    def test_manifest_values(self):
        seen = self._main_test({"worker_ready_timeout": "180", "server_ready_timeout": "45"})
        self.assertEqual(seen, {"server": 45.0, "worker": 180.0})

    def test_old_manifest_defaults(self):
        self.assertEqual(self._main_test({}), {"server": 30.0, "worker": 30.0})


if __name__ == "__main__":
    unittest.main()
