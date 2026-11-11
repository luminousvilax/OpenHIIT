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
import wave


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


def test_window(device: str) -> list[ET.Element]:
    def adb(*parts: str) -> bytes:
        return subprocess.run(["adb", "-s", device, *parts], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    adb("shell", "uiautomator", "dump", "/data/local/tmp/openhiit-media-test-window.xml")
    return list(ET.fromstring(adb("exec-out", "cat", "/data/local/tmp/openhiit-media-test-window.xml")).iter("node"))


def tap_node(device: str, node: ET.Element) -> None:
    bounds = node.get("bounds", "").replace("][", ",").strip("[]").split(",")
    x1, y1, x2, y2 = map(int, bounds)
    subprocess.run(["adb", "-s", device, "shell", "input", "tap",
                    str((x1 + x2) // 2), str((y1 + y2) // 2)], check=True)


def respond_permission(device: str, action: str) -> None:
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        nodes = test_window(device)
        suffixes = ({"permission_deny_button", "permission_deny_and_dont_ask_again_button"}
                    if action == "DENY" else
                    {"permission_allow_button", "permission_allow_all_button", "permission_allow_foreground_only_button"})
        target = next((n for n in nodes if n.get("resource-id", "").split("/")[-1] in suffixes), None)
        if target is None:
            labels = {"Don't allow", "不允许", "拒绝"} if action == "DENY" else {"Allow", "允许", "Allow all", "全部允许", "允许所有", "允许全部"}
            target = next((n for n in nodes if n.get("text") in labels and
                           n.get("package") not in {TEST_PACKAGE, "com.android.systemui"}), None)
        if target is not None:
            tap_node(device, target)
            return
        time.sleep(0.25)
    raise RuntimeError(f"No expected media permission dialog for {action}.")


def authorize_fixture_folder(device: str, folder: str) -> None:
    deadline = time.monotonic() + 60
    step = "roots"
    while time.monotonic() < deadline:
        all_nodes = test_window(device)
        nodes = [n for n in all_nodes if n.get("package") not in
                 {None, TEST_PACKAGE, "com.android.systemui"}]
        target = None
        if step == "roots":
            roots_list = next((n for n in nodes if n.get("resource-id", "").endswith("/roots_list")), None)
            if roots_list is not None:
                step = "downloads"
            else:
                target = next((n for n in nodes if n.get("content-desc") in
                               {"Show roots", "显示根目录", "显示菜单", "Open navigation drawer"}), None)
                if target is not None:
                    tap_node(device, target); step = "downloads"
        elif step == "downloads":
            roots_list = next((n for n in nodes if n.get("resource-id", "").endswith("/roots_list")), None)
            candidates = list(roots_list.iter("node")) if roots_list is not None else nodes
            target = next((n for n in candidates if n.get("text") in {"Downloads", "Download", "下载"}), None)
            if target is not None:
                tap_node(device, target); step = "fixture"
        elif step == "fixture":
            target = next((n for n in nodes if n.get("text") == folder or
                           n.get("content-desc", "").startswith(folder + ",")), None)
            if target is not None:
                tap_node(device, target); step = "inside"
        elif step == "inside":
            if any(n.get("text") in {"声音.wav", "picker.png", "nested"} for n in nodes):
                target = next((n for n in nodes if n.get("text") in
                               {"Use this folder", "USE THIS FOLDER", "使用此文件夹", "使用此文件夹中的文件"}
                               or n.get("resource-id", "").endswith("/action_menu_select")), None)
                if target is not None:
                    tap_node(device, target); step = "confirm"
        elif step == "confirm":
            target = next((n for n in nodes if n.get("text") in {"Allow", "允许"}), None)
            if target is not None:
                tap_node(device, target)
                return
            if not nodes and any(n.get("package") == TEST_PACKAGE for n in all_nodes):
                return
        time.sleep(0.3)
    raise RuntimeError("Could not authorize the current run's synthetic fixture folder.")


def reset_test_app(device: str) -> None:
    """Reset only the disposable package; some devices prohibit shell pm clear."""
    installed = subprocess.run(["adb", "-s", device, "shell", "pm", "path", TEST_PACKAGE],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if not installed.stdout.strip():
        return
    cleared = subprocess.run(["adb", "-s", device, "shell", "pm", "clear", TEST_PACKAGE],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if cleared.returncode != 0:
        # Explicitly target the test identity; never let Flutter infer an uninstall target.
        subprocess.run(["adb", "-s", device, "uninstall", TEST_PACKAGE], check=True)


def run_picker_suite(source: Path, device: str) -> int:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%SZ")
    artifacts = source / "build/device-picker" / stamp
    artifacts.mkdir(parents=True)
    folder = f"OpenHIIT-Picker-Test-{stamp}"
    device_folder = f"/sdcard/Download/{folder}"
    def adb(*parts: str) -> bytes:
        return subprocess.run(["adb", "-s", device, *parts], check=True, stdout=subprocess.PIPE).stdout
    with tempfile.TemporaryDirectory(prefix="openhiit-picker-device-") as temporary, ExitStack() as resources:
        project = Path(temporary)
        prepare_project(source, project)
        shutil.copy2(source / "tool/fixtures/media_browser_device_test.dart", project / "integration_test/media_test.dart")
        reset_test_app(device)
        adb("shell", "mkdir", "-p", f"{device_folder}/nested")
        resources.callback(adb, "shell", "rm", "-rf", device_folder)
        resources.callback(adb, "shell", "rm", "-f", "/data/local/tmp/openhiit-media-test-window.xml")
        (artifacts / "picker.png").write_bytes(crop_fixture(600, 800))
        with wave.open(str(artifacts / "声音.wav"), "wb") as output:
            output.setnchannels(1); output.setsampwidth(2); output.setframerate(8000)
            output.writeframes(bytes(3200))
        (artifacts / "unsupported.txt").write_text("Synthetic fixture; not supported media.\n")
        for local, remote in [("picker.png", "picker.png"), ("声音.wav", "声音.wav"),
                              ("声音.wav", "nested/nested.wav"), ("unsupported.txt", "unsupported.txt")]:
            adb("push", str(artifacts / local), f"{device_folder}/{remote}")
            if remote.endswith((".png", ".wav")):
                adb("shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", f"file://{device_folder}/{remote}")
        environment = dict(os.environ)
        environment["ORG_GRADLE_PROJECT_skipDependencyChecks"] = "true"
        subprocess.run(["flutter", "pub", "get", "--offline"], cwd=project, env=environment, check=True)
        for restore in (False, True):
            if restore:
                adb("shell", "am", "force-stop", TEST_PACKAGE)
            command = ["flutter", "test", "integration_test/media_test.dart", "-d", device,
                       "--no-pub", "--no-uninstall", "--timeout", "240s",
                       f"--dart-define=MEDIA_PICKER_FOLDER={folder}"]
            if restore:
                command.append("--dart-define=MEDIA_PICKER_RESTORE=true")
            process = subprocess.Popen(command, cwd=project, env=environment, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, bufsize=1)
            assert process.stdout is not None
            with (artifacts / ("restore.log" if restore else "test.log")).open("w") as log:
                try:
                    for line in process.stdout:
                        print(line, end="", flush=True); log.write(line); log.flush()
                        if "[PICKER-TEST] PERMISSION " in line:
                            respond_permission(device, line.split("[PICKER-TEST] PERMISSION ", 1)[1].strip())
                        elif "[PICKER-TEST] BACK" in line:
                            adb("shell", "input", "keyevent", "KEYCODE_BACK")
                        elif "[PICKER-TEST] AUTHORIZE" in line:
                            authorize_fixture_folder(device, folder)
                        elif "[PICKER-TEST] CAPTURE " in line:
                            name = line.split("[PICKER-TEST] CAPTURE ", 1)[1].strip()
                            if name and all(c.isalnum() or c in "_-" for c in name):
                                (artifacts / f"{name}.png").write_bytes(adb("exec-out", "screencap", "-p"))
                    code = process.wait()
                    if code != 0:
                        return code
                finally:
                    if process.poll() is None:
                        process.terminate(); process.wait()
        # Confirm that browsing/import/crop never altered any original fixture.
        for local, remote in [("picker.png", "picker.png"), ("声音.wav", "声音.wav"), ("声音.wav", "nested/nested.wav")]:
            assert adb("exec-out", "cat", f"{device_folder}/{remote}") == (artifacts / local).read_bytes()
        print(f"[PICKER-TEST] All cases passed; originals unchanged. Artifacts: {artifacts}", flush=True)
        return 0


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
    parser.add_argument("--crop", action="store_true", help="Run the crop suite instead, using the application browser and synthetic images. Screenshots and logs are saved under build/device-crop/.")
    parser.add_argument("--picker", action="store_true", help="Run the application browser suite, including real permission and folder dialogs and a fresh-process restoration pass.")
    arguments = parser.parse_args()
    if arguments.picker and (arguments.crop or arguments.background):
        parser.error("--picker selects a separate device suite.")
    if arguments.picker:
        return run_picker_suite(Path(__file__).resolve().parents[1], arguments.device)
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
            reset_test_app(arguments.device)
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
        environment["ORG_GRADLE_PROJECT_skipDependencyChecks"] = "true"
        subprocess.run(["flutter", "pub", "get", "--offline"], cwd=project, env=environment, check=True)
        command = [
            "flutter", "test", "integration_test/media_test.dart",
            "-d", arguments.device, "--no-pub", "--no-uninstall", "--timeout", "180s",
        ]
        if device_folder:
            command.append(f"--dart-define=MEDIA_CROP_FOLDER={Path(device_folder).name}")
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
                elif device_folder and "[CROP-TEST] PERMISSION " in line:
                    respond_permission(arguments.device, "ALLOW")
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
