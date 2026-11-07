#!/usr/bin/env python3
"""Run media tests from a temporary project with consistent test-only identities."""

import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET
import zlib


TEST_PACKAGE = "com.codepup.workout_timer.media_test"
APP_PACKAGE = "com.codepup.workout_timer"


def crop_fixture(width: int, height: int) -> bytes:
    """A lossless RGB test pattern with red, green, and blue vertical bands."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))

    row = b"".join(bytes(color) * (width // 3) for color in (
        (255, 0, 0), (0, 255, 0), (0, 0, 255)))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + row) * height))
            + chunk(b"IEND", b""))


def select_crop_fixture(device: str, action: str, folder: str) -> None:
    """Operate only the system picker and this run's synthetic fixture names."""
    def adb(*parts: str) -> bytes:
        return subprocess.run(["adb", "-s", device, *parts], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        adb("shell", "uiautomator", "dump", "/data/local/tmp/openhiit-crop-window.xml")
        root = ET.fromstring(adb("exec-out", "cat", "/data/local/tmp/openhiit-crop-window.xml"))
        nodes = list(root.iter("node"))
        native = [node for node in nodes if node.get("package") not in
                  {None, "com.android.systemui", TEST_PACKAGE, "com.android.launcher"}]
        if not native:
            time.sleep(0.2)
            continue
        if action == "CANCEL":
            adb("shell", "input", "keyevent", "KEYCODE_BACK")
            return
        targets = {action, Path(action).stem}
        def matches_file(node: ET.Element) -> bool:
            # DocumentsUI grid items expose the name together with size/date in
            # the accessibility description; list items expose plain text.
            return (node.get("text") in targets or node.get("content-desc") in targets
                    or node.get("content-desc", "").startswith(action + ","))

        target = next((node for node in native if matches_file(node)), None)
        if target is None:
            target = next((node for node in native if node.get("text") == folder), None)
        if target is None:
            target = next((node for node in native if node.get("text") in
                           {"Downloads", "Download", "下载"}), None)
        if target is None:
            target = next((node for node in native if node.get("content-desc") in
                           {"Show roots", "显示根目录", "显示菜单", "Open navigation drawer"}), None)
        if target is not None:
            bounds = target.get("bounds", "").replace("][", ",").strip("[]").split(",")
            x1, y1, x2, y2 = map(int, bounds)
            adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
            if matches_file(target):
                return
        time.sleep(0.3)
    raise RuntimeError(f"Could not select crop fixture {action!r} in the native picker.")


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
    parser.add_argument("--crop", action="store_true", help="Run the crop suite instead, using ADB to choose synthetic images in the real system picker. Screenshots and logs are saved under build/device-crop/.")
    arguments = parser.parse_args()
    if arguments.crop and arguments.background:
        parser.error("--crop and --background select different device suites.")
    source = Path(__file__).resolve().parents[1]

    def adb(*parts: str) -> None:
        subprocess.run(["adb", "-s", arguments.device, *parts], check=True)

    with tempfile.TemporaryDirectory(prefix="openhiit-media-device-") as temporary, ExitStack() as resources:
        project = Path(temporary)
        prepare_project(source, project)
        artifacts = None
        device_folder = None
        if arguments.crop:
            shutil.copy2(source / "tool/fixtures/image_crop_device_test.dart",
                         project / "integration_test/media_test.dart")
            stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%SZ")
            artifacts = source / "build/device-crop" / stamp
            artifacts.mkdir(parents=True)
            device_folder = f"/sdcard/Download/OpenHIIT-Crop-Test-{stamp}"
            adb("shell", "mkdir", "-p", device_folder)
            resources.callback(adb, "shell", "rm", "-rf", device_folder)
            resources.callback(adb, "shell", "rm", "-f", "/data/local/tmp/openhiit-crop-window.xml")
            for name, width, height in (("crop-large.png", 2400, 3200),
                                        ("crop-small.png", 120, 80)):
                fixture = artifacts / name
                fixture.write_bytes(crop_fixture(width, height))
                adb("push", str(fixture), f"{device_folder}/{name}")
                adb("shell", "am", "broadcast", "-a",
                    "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d",
                    f"file://{device_folder}/{name}")
            print(f"[CROP-TEST] Select files from Download/{Path(device_folder).name}.", flush=True)
            print(f"[CROP-TEST] Artifacts: {artifacts}", flush=True)
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
        log = (artifacts / "test.log").open("w") if artifacts else None
        try:
            for line in process.stdout:
                print(line, end="", flush=True)
                if log:
                    log.write(line)
                    log.flush()
                if device_folder and line.startswith("Installing "):
                    adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
                    adb("shell", "am", "start", "-n", f"{TEST_PACKAGE}/{APP_PACKAGE}.MainActivity")
                elif device_folder and "[CROP-TEST] PICK " in line:
                    action = line.split("[CROP-TEST] PICK ", 1)[1].strip()
                    select_crop_fixture(arguments.device, action, Path(device_folder).name)
                elif artifacts and "[CROP-TEST] CAPTURE " in line:
                    name = line.split("[CROP-TEST] CAPTURE ", 1)[1].strip()
                    if name and all(c.isalnum() or c in "_-" for c in name):
                        screenshot = subprocess.run(
                            ["adb", "-s", arguments.device, "exec-out", "screencap", "-p"],
                            check=True, stdout=subprocess.PIPE).stdout
                        (artifacts / f"{name}.png").write_bytes(screenshot)
                elif device_folder and "[CROP-TEST] REMOVE_SOURCE" in line:
                    adb("shell", "rm", f"{device_folder}/crop-large.png")
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
            if log:
                log.close()
            if process.poll() is None:
                process.terminate()
                process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
