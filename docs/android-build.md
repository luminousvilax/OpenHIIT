# Building Android APKs

Build a development APK for local debugging or a signed release APK for
installation. Run commands from the repository root. These instructions do not
publish an app or install anything automatically.

## Prerequisites

- Flutter and Android SDK tools on `PATH`; check them with `flutter doctor -v`.
- A compatible JDK. Local builds have been checked with JDK 21.
- Python 3 only if running the isolated device tests below.

The Android release workflow pins Flutter 3.41.6. Use that SDK when reproducing
CI. A newer SDK can require a newer Android Gradle Plugin than this repository's
AGP 8.9.1. If your local build fails specifically at that version check, the
build can be checked with an explicit override:

```sh
flutter build apk --debug --android-skip-build-dependency-validation
# For a locally signed release check, after configuring its key:
flutter build apk --release --android-skip-build-dependency-validation
```

This bypasses the version check without upgrading the build tools. Do not add it
to unrelated build failures; use a compatible SDK for routine release builds.

## Download mirrors and proxies

The repository configures two different downloads:

| Download | Configuration |
| --- | --- |
| Gradle distribution ZIP | Aliyun URL in `android/gradle/wrapper/gradle-wrapper.properties`, using the smaller `bin` archive. |
| Flutter engine Maven artifacts (`io.flutter`) | CFUG mirror, `https://storage.flutter-io.cn/download.flutter.io`, configured exclusively in `android/build.gradle`. |
| Other Android and Maven dependencies | Existing Google Maven, Maven Central, and Gradle Plugin Portal repositories. |

Changing the Gradle ZIP URL does not change the engine artifact repository.
The engine mirror applies to ordinary `flutter build` commands without requiring
a shell alias. Override it for the current terminal when needed:

```sh
# Use the official Flutter storage service instead of the repository default.
export FLUTTER_STORAGE_BASE_URL=https://storage.googleapis.com
```

To use the same mirror for Flutter SDK artifacts fetched by the Flutter command
itself, set `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`. This variable
does not change the Dart package registry. `PUB_HOSTED_URL` remains a separate,
optional setting. See [Flutter's mirror guide](https://docs.flutter.dev/community/china).

`android/settings.gradle` translates `http_proxy` / `HTTP_PROXY` and `https_proxy`
/ `HTTPS_PROXY` into the JVM properties Gradle uses. Lowercase variables take
precedence. An explicit JVM `proxyHost` is respected. No proxy address is stored
in the repository. For example, replace this illustrative endpoint with your
own HTTP proxy before using it:

```sh
export HTTPS_PROXY=http://proxy.example:8080
export HTTP_PROXY="$HTTPS_PROXY"
```

The environment bridge accepts HTTP proxy URLs without credentials. For
authenticated proxies or other proxy types, configure JVM properties in your
personal `~/.gradle/gradle.properties`. Configure any extra bypass patterns there
with `systemProp.http.nonProxyHosts`; environment `NO_PROXY` is not translated.
Loopback addresses bypass the proxy by default. See
[Gradle's networking reference](https://docs.gradle.org/current/userguide/networking.html).

## Development APK

```sh
flutter pub get
flutter build apk --debug
```

Output: `build/app/outputs/flutter-apk/app-debug.apk`. Debug signing uses the
local Android debug key; release signing configuration is not required.

For a smaller build targeting only 64-bit ARM phones:

```sh
flutter build apk --debug --target-platform android-arm64
```

For interactive development, use `flutter run -d <device-id>`. Development and
release builds both use application ID `com.codepup.workout_timer`.

## Signed release APK

Create a signing key once, or use your existing key for updates:

```sh
mkdir -p "$HOME/.keystores"
keytool -genkeypair -v \
  -keystore "$HOME/.keystores/openhiit-upload.jks" \
  -alias upload -keyalg RSA -keysize 2048 -validity 10000
```

Create the ignored file `android/key.properties`, replacing the values below.
`storeFile` is an absolute path to the keystore you chose:

```properties
storeFile=/absolute/path/to/openhiit-upload.jks
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=upload
```

The existing Gradle release configuration reads these four values. Keep the key
and passwords outside version control and retain a backup for future updates.
Build one universal installation APK:

```sh
flutter pub get
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`. To produce smaller
architecture-specific APKs instead:

```sh
flutter build apk --release --split-per-abi
```

Outputs are `app-armeabi-v7a-release.apk`, `app-arm64-v8a-release.apk`, and
`app-x86_64-release.apk` in the same directory. Choose the one matching the
device. Version metadata comes from `pubspec.yaml`; override it with
`--build-name <version> --build-number <integer>` when preparing an update.

An optional Play upload bundle is built with `flutter build appbundle --release`
and written to `build/app/outputs/bundle/release/app-release.aab`. An AAB is not
a directly installable APK. See the
[official Android release guide](https://docs.flutter.dev/deployment/android).

## Install and update

Enable USB debugging on the phone, accept the computer's authorization, then:

```sh
adb devices -l
adb -s <device-id> install -r build/app/outputs/flutter-apk/app-debug.apk
# Or install your signed release:
adb -s <device-id> install -r build/app/outputs/flutter-apk/app-release.apk
```

An update requires a compatible version code and the same signing certificate.
A debug key, your release key, and an upstream store signing key can differ.
If Android reports a signature mismatch, stop and choose the intended signing
key or a separate application ID. Uninstalling can remove app data; changing a
signature is not a data migration. Timer JSON exports do not include custom
media files.

## Verification

Run Flutter commands sequentially within one checkout. Builds and analysis can
regenerate the same platform plugin files; parallel release and debug tooling
can produce an invalid plugin registrant. Rerun the intended build on its own
instead of editing generated Java files.
When switching from tests or debug builds to release, use the build commands
above without `--no-pub` so Flutter can refresh release plugin registration.

```sh
flutter test test
flutter analyze
python3 tool/test_android_media.py --device <device-id>
```

The device wrapper copies sources into a temporary project with a consistent
test-only application ID, namespace, and manifests, and disables automatic
uninstall. It leaves the normal project identity unchanged. To also test timer
progression and playback requests while backgrounded and locked:

```sh
python3 tool/test_android_media.py --device <device-id> --background
```

The phone is intentionally locked during that check. Unlock it when requested
to finish the UI teardown. Listening for actual sound is a separate manual check.
