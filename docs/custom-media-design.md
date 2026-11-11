# Custom media and storage cleanup

## Purpose and scope

Extend OpenHIIT with locally selected audio cues and stage backgrounds while
preserving its interval structure, timing, notifications, and Restart workflow.
This document is the authoritative design for these additions.

The first release targets Android. Acceptance covers Android 14 and Android 16. Code and application UI remain in
English. Cross-device media transfer, synchronization, localization, looping
music, per-cue volume controls, and media bundles are
outside this release.

The behaviors below describe the implementation contract. Automated checks and
device acceptance are separate: a successful build or simulated player test does
not establish reliable audible playback under system lock-screen restrictions.

## Terms and existing behavior

A **timer configuration** is one saved workout. A **stage type** is Get Ready,
Warmup, Work, Rest, Break, or Cooldown. Multiple Work intervals may have different
exercise names, but all Work intervals within a configuration share the same
media settings. An exercise name never determines its background or sound
fallback.

The existing implementation provides these integration points:

| Responsibility | Implementation |
| --- | --- |
| Saved timer, time and sound settings | [`TimerType`](../lib/core/models/timer_type.dart), [`TimerSoundSettings`](../lib/core/models/timer_sound_settings.dart) |
| Stage generation and cue assignment | [`generateIntervalsFromTimer`](../lib/core/utils/interval_calculation.dart) |
| Editing and Save/Start behavior | [`EditTimer`](../lib/features/edit_timer/ui/edit_timer.dart), [`TimerCreationProvider`](../lib/core/providers/timer_creation_provider/timer_creation_provider.dart) |
| Running timer and completion overlay | [`RunTimer`](../lib/features/run_timer/workout.dart) |
| Global settings sections | [`SettingsPage`](../lib/features/settings/ui/settings.dart) |
| Portable JSON export | [`LocalFileUtil`](../lib/features/import_export_timers/utils/file_util.dart) |
| Background scheduling and playback | [`background_hiit_timer`](../packages/background_hiit_timer/README.md), based on version 1.2.3 |

Sound settings remain scoped to each timer. Work Sound also supplies Warmup;
Rest Sound also supplies Cooldown. Halfway, Countdown, and End are cue events,
not additional background stage types. End Sound belongs to completion of the
whole timer, not every interval. Existing cue eligibility and scheduling
thresholds remain unchanged, including transition cues scheduled shortly before
the next interval. No additional prompt to enter the next round is introduced.

## User experience

### File picker navigation

Android uses the full-screen application browser specified in
[In-app media picker](in-app-media-picker-design.md). That document is
authoritative for media-library access, shared read-only folder grants, separate
audio/image navigation and display preferences, cancellation, and access recovery.
Other platforms retain their existing file-picker behavior.

Confirmed files enter the same bounded cache-copy, validation, managed-import,
and image-crop flows described below. Browsing state is separate from timer
assignments; failed import or canceled crop preserves existing timer media.

### Sound settings

Keep the existing Sound page and its Work, Rest, Halfway, Countdown, End, and
conditionally visible Break settings. Each setting offers the existing built-in
sounds and None, plus an Import audio action. A selected custom file can be
previewed, replaced, changed to a built-in sound, or reset with Restore default.
None continues to mean silence.

Use the application media browser on Android. Accept MP3 and WAV, with a 20 MiB
per-file limit. Reject empty files and mismatched audio headers before assigning
them. Decoder or device compatibility can still fail during playback; use the
fallback behavior below. A canceled or failed selection preserves the previous
setting. The limit bounds import memory and storage; it is not a playback-length
limit or an automatic audio-trimming feature.

| Event | Playback behavior |
| --- | --- |
| A cue is triggered | Play once from the beginning. |
| Another cue arrives | Stop the previous cue and play the newest one. No overlap or delayed queue of old prompts. |
| The same countdown cue triggers again | Restart it from the beginning at the existing countdown ticks. A long phrase may be cut off. |
| Pause | Stop the cue immediately and cancel pending cue preparation. |
| Resume | Resume timing without replaying or continuing the interrupted cue. |
| Skip, Restart, or exit | Stop stale playback; preserve the existing timer operation and cue schedule. |
| Preview stops, its page is left, or the app leaves the foreground | Stop preview playback. Workout cues continue through the background service. |

Custom files use the same existing volume preference as built-in cues. The
background player and preview share source resolution and fallback rules. A
silent keepalive uses a separate player so it cannot truncate a spoken cue.

If a custom sound is missing, unreadable, or cannot play, use the built-in default
for that setting. Mark the custom selection as unavailable on the Sound page and
offer replacement. Do not show an error dialog during a workout or silently
overwrite the saved selection. A later successful playback clears the error.

### Background settings

Add Background immediately to the right of Sound. Editing order is General,
Sound, Background, then the existing exercise-name editor. Preserve that order
in the landscape navigation rail as well.

Provide a preview, Choose image or Replace image action, and Clear action for
each of the six stage types. Accept JPEG, PNG, and WebP through the media browser,
with the same 20 MiB per-file limit. After choosing a file, open a crop screen
before assigning it. Keep the existing Choose image, Replace image, and Clear
actions; do not add a separate crop or edit action to the Background page.
Background edits participate in the existing Save/Start workflow. Canceling the
picker or crop screen, or failing to decode, crop, or store the image, preserves
the previous assignment.

The crop frame uses the current app window's portrait aspect ratio, even when
selecting from landscape. Drag to position the image and pinch to zoom; the image
must fill the frame. Reset restores the initial centered crop. The chosen ratio
and composition stay fixed if the device rotates while cropping. Manual rotation,
flipping, and filters are outside this change.

Save only the cropped result, losslessly encoded as PNG, with width at most 1440
and height at most 3200 pixels. Preserve its aspect ratio and do not upscale small
images. Bound source decoding to 16 megapixels and 8192 pixels per edge to limit
memory use; available crop resolution is measured from this decoded image. Show
an inline warning when the selected region has fewer pixels than the current
device's portrait background needs, subject to the output limit. The warning does
not prevent applying the crop. Do not retain an additional original or crop
coordinates: changing the composition later requires selecting the original
again. The external source remains unchanged.

Each configuration owns its background assignments independently. Use the
current interval's explicit stage metadata to select the image; all Work names
and repetitions use the Work assignment. Select backgrounds when the actual
stage changes, rather than when an early transition cue plays. Show images behind
the entire running layout with the existing fixed dark overlay. Newly cropped
backgrounds use `BoxFit.contain` in both workout orientations, preserving the
selected composition. Any uncovered area uses the
original stage color. Their display decoding supports the 1440 by 3200 output
limit rather than reducing the long edge to 2048 pixels.

Background page cards retain their wide, 140-logical-pixel-high previews. Both
new and legacy images use centered `BoxFit.cover` in these cards, with the dark
overlay and stage name. The preview shows a detail of the saved image to fill the
card; it does not modify the saved crop or change workout rendering. Decode new
portrait crops for the preview's width rather than shrinking them to the card's
short height and enlarging them again.

Previously imported backgrounds keep their existing centered `BoxFit.cover`
display and 2048-pixel decode bounds until the user chooses a replacement and
confirms a crop. Do not automatically crop or rewrite existing files. An
adjustable overlay control is not added.

Missing, unreadable, or undecodable images fall back to the existing stage color.
An unset or cleared image uses the original visuals without an image overlay.
Retain the existing completion screen; it has no separate custom background.

### Storage in global Settings

Insert a **Storage** section after **Appearance** and before **About**, following
the existing settings-section layout. Include the action **Clean unused media**
with this explanation:

> Remove imported audio and images that no timer uses. You will be asked to confirm.

Tapping the action scans managed files and saved references without deleting
anything. When candidates exist, show a confirmation dialog:

- Title: **Clean unused media?**
- Show the estimated file count and reclaimable size.
- Explain that deletion is permanent and applies only to unused imported copies.
- Explain that saved timer settings, files still in use, active editor or preview
  references, and original files outside the app are preserved.
- Actions: **Cancel** and **Clean**.

Cancel, back, or dismiss performs no deletion. Clean rescans current references
and deletes only files still unused. Disable repeated requests while scanning or
cleaning. Report the actual number removed and bytes freed. When there are no
candidates, show **No unused media to clean.** If some deletions fail, report the
successful result and failure count, and allow retry. If saved references cannot
be read, stop cleanup rather than interpreting the error as an empty database.

Cleanup is unavailable while a workout service is running, including a paused
workout. Ask the user to finish the workout first. The feature does not clear
databases, preferences, application caches, exported JSON, or unrelated files in
the app's private directory.

## Storage ownership and lifecycle

[`MediaStore`](../lib/core/media/media_store.dart) owns imports and cleanup.
Copy selected bytes into a dedicated persistent directory under application
support storage:

```text
media/
  audio/<uuid>_<sanitized-name>.mp3
  audio/<uuid>_<sanitized-name>.wav
  images/<uuid>_<sanitized-name>.png
  images/crop1-<uuid>_<sanitized-name>.png
```

The `crop1-` prefix identifies images produced by the crop flow and their complete
composition display policy. Unmarked image references retain the legacy display
policy. Both use the existing string background assignments and cleanup rules;
no database migration is required. Newly selected image originals remain only in
memory during cropping and are not copied into managed storage.

The selected external file remains unchanged. Store timer media references such
as `local:audio/<uuid>_cue.wav`; never store picker cache paths or
installation-specific absolute paths in them, or rely on external URI grants for
playback. Both the UI and service resolve the reference through
[`MediaFiles`](../packages/background_hiit_timer/lib/media_files.dart).
Validate references and reject traversal, absolute paths, and linked media roots,
folders, or files.

Picker navigation is separate from managed media and is owned by Android's
`MediaBrowserState`. Its two media-type records and shared folder grants follow
[the picker state contract](in-app-media-picker-design.md#state-cancellation-and-recovery).
These grants are never needed for workout playback. Copy confirmed source files
to unique temporary cache folders with the same 20 MiB bound, then remove those
copies when import/cropping completes, fails, or is canceled.

Write an import to a temporary `.part` file, flush it, then rename it before
assigning a reference. Protect newly imported files until the editor accepts or
abandons the assignment. A failed import leaves the previous configuration
intact. A process interruption may leave an unreferenced temporary file; a later
manual cleanup may remove it.

Do not delete a file eagerly when a setting is replaced or cleared, a draft is
discarded, or a timer is deleted. Another timer, an open draft, or a running
workout may still use it. In-device timer copies retain media references. A file
becomes eligible for manual cleanup only after its last saved or active reference
is gone. Separate selections may create separate copies; a media library and
content deduplication are not required.

### Definition of unused and cleanup algorithm

The saved reference set is the union of every saved timer's custom sound values
and background assignments, including currently hidden or disabled stages.
Do not use only the selected timer, visible fields, or the home page's cached
timer list. Add active editor, workout, preview-session, and pending-import
references to the protected set.

1. Serialize cleanup with media imports and timer saves or deletions.
2. Reject cleanup while the background workout service is active. An inability
   to determine service state stops cleanup.
3. Read all saved configurations directly from the repository. A read failure
   stops cleanup before any file is deleted.
4. Inspect regular files directly inside the managed audio and images folders.
   Do not traverse links or nested directories.
5. Subtract saved and active references to estimate candidates for confirmation.
6. After confirmation, repeat the scan under the same serialization mechanism.
   Recheck active references before each deletion, so newly retained files are
   kept. Confirmation counts are estimates, not a fixed deletion list.
7. Delete eligible files, count successful deletions, and report individual
   filesystem failures without claiming they succeeded.

The background service runs in another isolate; a foreground in-memory reference
set alone is insufficient to establish that a running workout is safe to clean.
Blocking cleanup while that service runs protects its loaded interval snapshot.

## Persistence and background integration

The main database advances from version 8 to 9. Add a `backgrounds` JSON column to
TimerTable, defaulting to an empty object, and a `stage` column to IntervalTable,
defaulting to an empty string. Fresh creation and upgrade must yield the same
schema. Existing timers keep their current sound values and original visuals.
Sound columns already hold strings and can store either the existing built-in
identifier, silence, or a local reference without additional sound columns.

Generated intervals carry an explicit stage key independently of their displayed
exercise names. The background service's temporary database advances to version
2 to persist that metadata. Legacy rows without metadata use the previous
standard-name classification until regeneration.

The repository uses a local copy of `background_hiit_timer` 1.2.3 with its MIT
license and original audio assets. Modifications are limited to media source
resolution, stage metadata, cue cancellation and replacement, and the separate
keepalive player. Resolve custom files in the service isolate. File decoding or
audio preparation must not block the timer tick; serialize player operations and
invalidate obsolete requests when a newer cue or control action arrives.

Preserve interval durations, repeat counts, Restart semantics, skip behavior,
notification setup, and cue trigger thresholds. Do not infer a new cue on Resume
or add new sounds for previously silent stages. Background and lock-screen
behavior must be checked on physical devices, not inferred from preview playback.

## Import, export, and two-device use

Retain the existing JSON save/share/import workflow. Export timer parameters and
built-in sound choices, replacing custom sound references with the corresponding
built-in defaults. Omit background assignments and media bytes. Apply these rules
to the exported representation only; do not mutate the saved timer.

Imports ignore device-local media references rather than accidentally resolving
them against the receiving installation. They start with default sounds for such
references and no custom backgrounds. Existing portable timer files remain
supported. The two phones must each import and configure their media independently;
reimporting a JSON export does not restore local media settings, even on the same
installation. Uninstalling or clearing app data removes private media.

## Verification and acceptance

Automated coverage must protect the following behaviors:

- Database upgrades preserve existing timers and initialize empty backgrounds.
- Database round trips preserve local references; portable export and import
  remove them without mutating the source configuration.
- Copies share file references but have independent background-assignment maps.
- Work stage identity survives exercise renaming and repeated rounds.
- Import copies survive deletion of the original and invalid imports preserve
  the previous choice.
- Crops preserve the selected region and aspect ratio, stay within 1440 by 3200
  pixels, and never upscale; zoom and pan cannot expose empty areas.
- Crop cancellation preserves the previous assignment and creates no managed
  file. Low-resolution crops show a warning but can still be applied.
- New crop references round-trip and display completely in both workout
  orientations; legacy references retain centered cover rendering. Stage cards
  use centered cover previews for both new and legacy images without changing
  the saved crop.
- Cleanup keeps all saved references, shared references, pending imports, and
  active drafts or previews; rechecks after confirmation; aborts on repository
  failure or a running workout; and does not follow links or touch outside files.
- Cue replacement, repeated countdown playback, and pause cancellation discard
  obsolete requests.
- The Storage action requires confirmation; cancellation does not delete files.
- Application picker behavior follows the automated and device acceptance cases in
  [its verification section](in-app-media-picker-design.md#verification).


Perform this acceptance matrix independently on Android 14 and Android 16.
Record test scope, observed results, and limitations. Do not include device
models, manufacturers, vendor system names, serials, system builds, or personal
information in design documents. A blank checkbox means not yet verified.

| Scenario | Android 14 | Android 16 |
| --- | --- | --- |
| Import, preview, replace, clear, save, and reopen media settings | [ ] | [ ] |
| Persist media after app restart and removal of the original files | [ ] | [ ] |
| Correct stage images in portrait and landscape; readable controls | [ ] | [ ] |
| Pick, drag, pinch, cancel, apply, and reopen cropped backgrounds; full landscape composition and low-resolution warning | [x] | [ ] |
| Actual custom cue playback and fallback in the foreground | [ ] | [ ] |
| Cue playback and continued timing after switching apps | [ ] | [ ] |
| Cue playback and continued timing while locked | [x] | [ ] |
| Replacement of a longer cue during countdown; no overlapping prompts | [ ] | [ ] |
| Pause, Resume, Skip, Restart, completion, and exit retain their semantics | [ ] | [ ] |
| Referenced media survives cleanup; unused copies are removed after confirmation | [x] | [ ] |
| Existing timers, built-in sounds, None, and JSON transfer remain usable | [ ] | [ ] |

Run automated checks with `flutter test test` and `flutter analyze`. Compare
analysis results with the pre-change baseline when reporting existing lints.
Run the Android picker regression tests on the host, without a device:

```sh
cd android
./gradlew :app:testDebugUnitTest
```

If the installed Flutter SDK requires the documented AGP version-check override,
add `-PskipDependencyChecks=true` to that Gradle command.

Run device tests through the isolated-project wrapper:

```sh
python3 tool/test_android_media.py --device <device-id>
```

The wrapper copies application sources into a temporary project and aligns its
Gradle application ID, namespace, and all source manifests with
`com.codepup.workout_timer.media_test`. It keeps MainActivity's fully qualified
class name and labels the installation OpenHIIT Media Test. It also passes
`--no-uninstall` to Flutter. Normal project sources and their application ID are
unchanged. Overriding only the built APK's ID is insufficient: Flutter can use
the source manifest's package ID for cleanup.
The device fixture lives in `tool/fixtures/media_test.dart`, outside the normal
integration-test directory. The wrapper places it in its temporary project; this
keeps ordinary integration-test discovery from running it against the production
package identity.

Run the browser suite, including real permissions and folder authorization, with:

```sh
python3 tool/test_android_media.py --device <device-id> --picker
```

This resets only the isolated test application's data, exercises synthetic files,
and repeats restoration in a fresh application process. It leaves the normal
application untouched and removes its synthetic source folder afterward.

Run the separate image crop suite with:

```sh
python3 tool/test_android_media.py --device <device-id> --crop
```

This uses `tool/fixtures/image_crop_device_test.dart` with the same isolated
identity. Keep the device unlocked and do not interact with it during the run.
The wrapper uploads synthetic PNGs, authorizes image access through the system
and operates the application browser, and removes the temporary Downloads folder afterward. It saves fixtures,
logs, and screenshots in `build/device-crop/<UTC timestamp>/`. Screenshots wait
for Android's rotation animation to settle. The crop suite and `--background`
select different fixtures and cannot be combined.

Add `--background` to run a fourth integration test that switches to the launcher
and then locks the phone while collecting timer snapshots and native custom-cue
acceptance events. The wrapper wakes and reopens the test app afterward; unlock
the phone manually when requested to finish UI teardown. This checks native
playback requests and timer progression, rather than independently confirming
audible sound.

### Validation record

Previous automated checks covered custom-audio assignment, background decoding,
Unicode filenames, managed storage, cleanup, and image crop geometry and gestures.
Earlier Android 14 device checks covered crop selection/cancellation, persistence,
source-file removal, native cue requests, and locked-screen timing. These results
predate the in-app picker and do not validate its permission or browsing behavior.
Android 16 acceptance remains unverified.

The current picker and crop verification record is maintained in
[In-app media picker](in-app-media-picker-design.md#verification).
Unchecked entries in the physical-device matrix remain open. Automated tests do
not replace visual-readability and physical-device checks.
