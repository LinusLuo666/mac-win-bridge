import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "audio-bridge-manager.py"
SPEC = importlib.util.spec_from_file_location("audio_bridge_manager", SCRIPT)
manager = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(manager)


class AudioBridgeManagerTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        state_dir = Path(self.temporary_directory.name)
        manager.STATE_DIR = state_dir
        manager.PID_FILE = state_dir / "mac-audio.pid"
        manager.LOG_FILE = state_dir / "mac-audio.log"
        manager.CONFIG_FILE = state_dir / "config.json"

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_latency_defaults_and_persists(self):
        self.assertEqual(manager.load_config()["latency_ms"], 50)

        manager.save_config("192.168.137.1", 5055, 80)

        self.assertEqual(
            manager.load_config(),
            {"host": "192.168.137.1", "port": 5055, "latency_ms": 80},
        )

    def test_invalid_persisted_latency_falls_back_to_default(self):
        manager.ensure_state_dir()
        manager.CONFIG_FILE.write_text(
            json.dumps({"host": "192.168.137.1", "port": 5055, "latency_ms": 80.5})
        )

        self.assertEqual(manager.load_config()["latency_ms"], 50)

    def test_start_forwards_latency_in_process_environment(self):
        with mock.patch.object(manager.subprocess, "Popen") as popen:
            popen.return_value.pid = 1234

            message = manager.start_audio("192.168.137.1", 5055, 20)

        self.assertIn("PID 1234", message)
        environment = popen.call_args.kwargs["env"]
        self.assertEqual(environment["AUDIO_LATENCY_MS"], "20")
        self.assertEqual(manager.load_config()["latency_ms"], 20)

    def test_page_exposes_latency_range_presets_and_effective_value(self):
        manager.save_config("192.168.137.1", 5055, 50)
        with mock.patch.object(manager, "tcp_status", return_value=(True, "ok")), \
             mock.patch.object(manager, "detect_audio_processes", return_value=[]), \
             mock.patch.object(manager, "tail_log", return_value=""):
            page = manager.render_page()

        self.assertIn('min="10"', page)
        self.assertIn('max="120"', page)
        for latency in (20, 50, 80):
            self.assertIn(f'data-latency="{latency}"', page)
        self.assertIn("53.3 ms effective", page)
        self.assertIn("Port check", page)
        self.assertIn('http-equiv="refresh" content="5"', page)


if __name__ == "__main__":
    unittest.main()
