"""Safety checks for resetting a disposable Android media-test installation."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
import xml.etree.ElementTree as E
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("media_runner", Path(__file__).with_name("test_android_media.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ResetTestApplicationTest(unittest.TestCase):
    def test_absent_app_needs_no_mutation(self):
        with patch.object(runner.subprocess, "run", return_value=SimpleNamespace(stdout=b"", returncode=1)) as run:
            runner.reset_test_app("fixture-device")
            self.assertEqual(run.call_count, 1)
            self.assertIn("path", run.call_args.args[0])

    def test_successful_clear_does_not_uninstall(self):
        with patch.object(runner.subprocess, "run", side_effect=[
            SimpleNamespace(stdout=b"package:fixture.apk", returncode=0),
            SimpleNamespace(stdout=b"Success", returncode=0),
        ]) as run:
            runner.reset_test_app("fixture-device")
            self.assertEqual(run.call_count, 2)
            self.assertTrue(all(call.args[0][-1] == runner.TEST_PACKAGE for call in run.call_args_list))
            self.assertFalse(any("uninstall" in call.args[0] for call in run.call_args_list))

    def test_restricted_clear_removes_only_the_disposable_identity(self):
        with patch.object(runner.subprocess, "run", side_effect=[
            SimpleNamespace(stdout=b"package:fixture.apk", returncode=0),
            SimpleNamespace(stdout=b"", returncode=255),
            SimpleNamespace(stdout=b"Success", returncode=0),
        ]) as run:
            runner.reset_test_app("fixture-device")
            self.assertEqual(run.call_args.args[0], ["adb", "-s", "fixture-device", "uninstall", runner.TEST_PACKAGE])
            for call in run.call_args_list:
                self.assertNotIn(runner.APP_PACKAGE, call.args[0])


class AuthorizeFixtureFolderTest(unittest.TestCase):
    def test_stale_test_folder_is_not_authorized_before_entering_current_run(self):
        def node(text="", description="", resource=""):
            return E.Element("node", {"package": "com.android.documentsui", "text": text,
                "content-desc": description, "resource-id": resource, "bounds": "[0,0][100,100]"})
        old = [node("old-run"), node("picker.png"), node("nested"), node("USE THIS FOLDER"), node(description="Show roots")]
        download = [node("Downloads")]
        fixture = [node("current-run")]
        inside = [node("picker.png"), node("USE THIS FOLDER")]
        confirm = [node("Allow")]
        taps = []
        with patch.object(runner, "test_window", side_effect=[old, download, fixture, inside, confirm]), \
             patch.object(runner, "tap_node", side_effect=lambda device, n: taps.append(n.get("text") or n.get("content-desc"))), \
             patch.object(runner.time, "sleep"):
            runner.authorize_fixture_folder("fixture-device", "current-run")
        self.assertEqual(taps, ["Show roots", "Downloads", "current-run", "USE THIS FOLDER", "Allow"])


if __name__ == "__main__":
    unittest.main()
