#!/usr/bin/env python3
"""Run media tests from a temporary project with consistent test-only identities."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


TEST_PACKAGE = "com.codepup.workout_timer.media_test"
APP_PACKAGE = "com.codepup.workout_timer"


def prepare_project(source: Path, destination: Path) -> None:
    ignore = shutil.ignore_patterns(
        ".dart_tool", "build", ".gradle", ".kotlin", ".cxx",
        "key.properties", "*.jks", "*.keystore",
    )
    for name in (
        "lib", "packages", "assets", "google_fonts", "android",
        "integration_test", "pubspec.yaml", "pubspec.lock", "analysis_options.yaml",
    ):
        path = source / name
        if path.is_dir():
            shutil.copytree(path, destination / name, ignore=ignore)
        else:
            shutil.copy2(path, destination / name)

    shutil.copy2(source / "tool/fixtures/media_test.dart",
                 destination / "integration_test/media_test.dart")

    gradle = destination / "android/app/build.gradle"
    content = gradle.read_text()
    namespace = f"namespace '{APP_PACKAGE}'"
    application_id = f'applicationId "{APP_PACKAGE}"'
    if content.count(namespace) != 1 or content.count(application_id) != 1:
        raise RuntimeError("Cannot identify the Android namespace and application ID safely.")
    content = content.replace(namespace, f"namespace '{TEST_PACKAGE}'")
    content = content.replace(application_id, f'applicationId "{TEST_PACKAGE}"')
    gradle.write_text(content)

    manifest = destination / "android/app/src/main/AndroidManifest.xml"
    content = manifest.read_text()
    if content.count(f'package="{APP_PACKAGE}"') != 1:
        raise RuntimeError("Cannot identify the source manifest package safely.")
    content = content.replace(f'package="{APP_PACKAGE}"', f'package="{TEST_PACKAGE}"')
    content = content.replace('android:name=".MainActivity"', f'android:name="{APP_PACKAGE}.MainActivity"')
    content = content.replace('android:label="OpenHIIT"', 'android:label="OpenHIIT Media Test"')
    manifest.write_text(content)
    for variant in ("debug", "profile"):
        manifest = destination / f"android/app/src/{variant}/AndroidManifest.xml"
        manifest.write_text(manifest.read_text().replace(
            f'package="{APP_PACKAGE}"', f'package="{TEST_PACKAGE}"'))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Authorized ADB device serial.")
    parser.add_argument("--background", action="store_true", help="Also background and lock the phone during playback checks; manual unlock is needed afterward.")
    arguments = parser.parse_args()
    source = Path(__file__).resolve().parents[1]

    def adb(*parts: str) -> None:
        subprocess.run(["adb", "-s", arguments.device, *parts], check=True)

    with tempfile.TemporaryDirectory(prefix="openhiit-media-device-") as temporary:
        project = Path(temporary)
        prepare_project(source, project)
        environment = dict(os.environ)
        subprocess.run(["flutter", "pub", "get", "--offline"], cwd=project, env=environment, check=True)
        command = [
            "flutter", "test", "integration_test/media_test.dart",
            "-d", arguments.device, "--no-pub", "--no-uninstall", "--timeout", "180s",
        ]
        if arguments.background:
            command.append("--dart-define=MEDIA_BACKGROUND_CHECKS=true")
        process = subprocess.Popen(command, cwd=project, env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1)
        assert process.stdout is not None
        try:
            for line in process.stdout:
                print(line, end="", flush=True)
                if "[MEDIA-TEST] BACKGROUND_READY" in line:
                    adb("shell", "input", "keyevent", "KEYCODE_HOME")
                elif "[MEDIA-TEST] LOCK_READY" in line:
                    adb("shell", "input", "keyevent", "KEYCODE_SLEEP")
                elif "[MEDIA-TEST] UNLOCK_REQUIRED" in line:
                    adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
                    adb("shell", "am", "start", "-n", f"{TEST_PACKAGE}/{APP_PACKAGE}.MainActivity")
                    print("[MEDIA-TEST] Unlock the phone to finish the UI teardown.", flush=True)
            return process.wait()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
