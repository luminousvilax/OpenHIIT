# In-app media picker

## Purpose and status

The Android media picker is an application-owned, full-screen browser for audio
cues and background images. It replaces system single-file selection so directory
restoration, sorting, layout, highlighting, and navigation follow the same rules.
The system still provides media permission dialogs and folder authorization.

The filename retains `fallback` so existing links remain valid. This is the
active picker design, not a dormant alternative. General media import, image
crop, managed storage, and timer assignment rules remain authoritative in
[Custom media and storage cleanup](custom-media-design.md).

Acceptance targets Android 14 and Android 16. Verification records contain only
Android versions, test scope, results, and limitations; omit device manufacturers,
models, vendor system names, serials, system build identifiers, and personal data.

## Sources and permissions

Use two visible source tabs: **Media library** and **Folders**. Both browse one
directory level at a time; neither recursively flattens descendants into the
current directory. The initial source is Media library. Later openings restore
the source and directory of the last confirmed file for the current media type.

### Media library

Read Android's existing MediaStore index. Present a directory hierarchy grouped
by storage volume and relative path, limited to accessible files in supported
formats. This is a view of indexed media, not a complete filesystem browser.
Directories without accessible supported media do not appear. Unindexed files
require explicit folder authorization. Do not maintain an additional index or
scan storage continuously.

Request only the current media type's read permission on its first opening:
`READ_MEDIA_AUDIO` for audio and `READ_MEDIA_IMAGES` for images. Support
`READ_MEDIA_VISUAL_USER_SELECTED` for partial image access. Older Android releases
use their applicable storage read permission. Do not request video, write,
location-metadata, or all-files access.

After denial, keep the browser usable with **Allow access** and **Add folder**.
Do not automatically request again on later openings. Explicit authorization can
request again or open application settings when Android disallows another dialog.
Refresh permission state and visible contents after returning to the application.

Partial image access is a normal browsing mode. Show **Only authorized images are
shown.** and **Manage accessible images**. The latter lets the user adjust the
accessible images through the system authorization flow. Folder access remains
independent of library permission.

See Android's [media access](https://developer.android.com/training/data-storage/shared/media)
and [partial image access](https://developer.android.com/about/versions/14/changes/partial-photo-video-access)
guidance.

### Authorized folders

Keep one persistent folder list shared by audio and images. **Add folder** uses
`ACTION_OPEN_DOCUMENT_TREE` and retains read-only access. Each grant covers the
selected directory and its descendants. Existing single-file grants do not
authorize parent-directory browsing.

Show immediate child folders, including folders whose supported contents are not
yet known, and filter files for the current media type. Do not recursively scan
authorized trees to hide empty or unrelated subfolders. Verify navigation against
the granted tree, including providers with opaque document IDs.

Adding and removing folders take effect immediately, even if file selection is
subsequently canceled. Reauthorizing the same tree updates its entry without
creating a duplicate. Canceling the system authorization dialog changes nothing.
Multiple roots may overlap; removing one does not remove another root or grant.

**Remove** releases the selected root's retained read grant and clears any audio
or image navigation record that uses that root. Those records return to the
Folders home, retaining sorting and layout. It never deletes originals or managed
media. Other roots and media-library records remain unchanged.

Android restricts authorization of storage roots, the Download root, Android/data,
and Android/obb. The browser must respect these restrictions. Access outside a
granted tree requires another explicit authorization. See Android's
[directory access guidance](https://developer.android.com/training/data-storage/shared/documents-files).

## Interface and navigation

Use the application's Material styling and English labels.

| Area | Behavior |
| --- | --- |
| Top bar | Close button and Choose audio or Choose image. Close cancels directly to the editor from any depth. |
| Source bar | Media library and Folders tabs. Switching sources does not confirm a file or automatically request another permission. |
| Path bar | Parent-folder action, horizontally readable current path, and Refresh. |
| Tools | Name, Modified, or Size sorting; ascending/descending direction; image-preview size and filename toggles; list/grid toggle. |
| Content | Immediate subfolders first, then supported files in the current directory. |
| Folders home | Shared authorized roots, Add folder, and a per-root Remove menu. |

System Back and the back gesture move up one directory. An authorized root's
parent is the Folders home; navigation cannot ascend into an unauthorized parent.
Back at the current source home exits. Close always exits directly, including
while loading or copying.

Images default to a thumbnail grid and Modified descending. Audio defaults to a
list and Name ascending. Both support list/grid switching. Changing layout never
changes sorting. Folders remain first in Name ascending, independent of file
sorting. Unknown metadata sorts last in either direction, with deterministic
filename and identity tie-breaking.

List files show names, sizes, and modification dates when available. Image grids
show three columns by default; the preview-size button switches between three
columns (small) and two (large). The filename button immediately left of the
list/grid button toggles image filenames, initially visible. Both preferences
persist immediately, including after cancellation, and are shared across the two
image sources. Audio presentation keeps its existing behavior.

Images fill the available preview region with contain fitting, preserving the
complete picture. Visible filenames use smaller text and less padding to leave
more room for images. Hiding filenames gives images the whole tile, except for a
small inset; folder names remain visible for navigation. Accessible image names
remain available when visual filenames are hidden. List mode always shows names.
Thumbnail failures use a placeholder and never prevent file selection.

Highlight the last confirmed file passively. Match identity first, then a unique
exact filename in the remembered directory. Missing or ambiguous matches receive
no highlight. After restoration, sorting, or layout changes, scroll a matched file
toward the viewport center while respecting scroll bounds. No file is selected
or imported merely because the browser opens.

Single-tap confirmation starts the existing audio import or image-crop flow.
Retain MP3/WAV and JPEG/PNG/WebP filtering, the existing 20 MiB import limit,
validation, and managed-copy storage. No additional confirmation, in-browser
playback, search, rename, move, copy, or delete-file controls are introduced.

## State, cancellation, and recovery

Android is the sole persistent owner of browser state. Keep one navigation and
view record for audio and another for images, shared across timers and stages.
Records and folder grants are excluded from timer export. Flutter holds only the
current session's navigation and visible data. Existing timer media assignments
remain valid on upgrade. The new browser establishes its navigation records on
its first confirmed selections; legacy single-file hints are not folder grants.

| Action | Persistent effect |
| --- | --- |
| Confirm a file | Remember source, directory/trail, original URI, and display name before copying, validating, or cropping. |
| Browse or switch sources, then close | Preserve the previous confirmed location and file. |
| Change sorting, layout, image filename visibility, or preview size | Persist immediately for that media type, shared across both sources. Closing does not roll back the change. |
| Add or remove a folder | Persist immediately, independently of file selection. |
| Fail import or cancel crop | Keep the confirmed navigation record and the timer's previous media assignment. Remove temporary copies. |
| Lose access unexpectedly | Preserve the folder list, remembered location, and timer media. |
| Intentionally remove a root | Clear only navigation records that use it; retain view preferences and managed media. |

For an unavailable remembered directory, display its saved location and an
explicit error. Offer Retry, authorization recovery where applicable, source
switching, and navigation to the source home. Never silently replace the saved
location or erase a timer's assignment. A disappeared media-library directory
and a merely empty authorized directory are distinct: the latter remains
browsable and shows an empty message.

## Implementation and resource bounds

- `lib/core/media/media_browser.dart` defines channel messages, locations,
  deterministic sorting, and highlight matching.
- `lib/shared/ui/widgets/media_browser_screen.dart` owns the browser route,
  navigation, rendering, and current-session state, including filename visibility
  and image-preview size.
- `AndroidMediaPicker` handles runtime permissions, tree grants, immediate-child
  enumeration, MediaStore queries, bounded cache copies, and thumbnails.
- `MediaBrowserState` owns the shared roots and the two persistent records.
- `media_picker.dart` connects the browser result to existing import and crop
  handling. Other platforms retain their current file picker.

Run listing and copying away from the UI thread. Thumbnail work uses two workers,
a bounded 48-request queue, cancellation of obsolete listing/thumbnail requests,
sampled decoding bounded to a 512-pixel edge, and a 48-entry Flutter
thumbnail-future cache. Visible lists/grids are built lazily. Temporary original
copies are bounded during copying and are removed after import, crop cancellation,
copy failure, or closing before the copy result returns.

No extra background service or continuous indexing is required. Build size,
large-directory latency, and peak memory require measurement; no numerical
performance claim is implied by these bounds.

## Verification

Complete automated verification before physical-device testing. Native tests cover
permission modes and request history, directory boundaries, opaque IDs, shared
read-only grants, independent persistence, file copying, and size/empty-file
failures. Flutter tests cover sorting, highlighting, scrolling, restoration,
source switching, Back/Close, cancellation, permission/error UI, and the existing
import/crop cleanup contract.

Device tests use the isolated test application through
`tool/test_android_media.py`; never uninstall the normal application. Use only
synthetic fixtures and record results without personal device information. The
runner resets only the disposable test app; if shell data clearing is blocked,
it explicitly uninstalls that test identity before reinstalling. The restoration
pass retains its data.
Exercise real media-library queries and folder authorization in addition to
simulated host providers. A host test does not establish actual system permission
or provider behavior.

| Check | Status |
| --- | --- |
| Native host tests | 22 passed, including permission, grants, copying, persistence, and obsolete-thumbnail cancellation. |
| Device-runner safety checks | 4 Python tests passed, including disposable-package reset and exact fixture-folder authorization. |
| Flutter tests and analysis | 78 tests passed. Analysis has no errors or warnings and retains 18 existing informational diagnostics. |
| Android build | Debug APK built with the documented Flutter/AGP version-check override. |
| Android 14 physical-device acceptance | 3 browser cases, 1 fresh-process restoration case, and 4 crop regression cases passed. Browser fixtures remained byte-for-byte unchanged; all synthetic source directories were removed. The normal application version remained unchanged. |
| Android 16 physical-device acceptance | Not verified; no connected Android 16 target. |

Record actual results and remaining limits after verification. Full/partial/denied permissions, reauthorization, restart restoration, unavailable
sources, independent audio/image preferences, import/crop cancellation, and
original-file preservation are separate acceptance cases. Partial-image permission detection and management UI, revoked-folder failures,
and multiple-root state persistence have host coverage. Actual partial-photo
selection/reselection, permanent-denial/settings recovery, folder reauthorization,
overlapping grants, and unavailable external providers still need physical
acceptance. Android 16, large-directory latency,
peak memory, and APK-size overhead remain unmeasured. The physical image fixtures
were PNGs; this run does not establish JPEG/EXIF behavior or subjective photo
quality.

### Image-grid display adjustment

The image-grid filename toggle, smaller labels, expanded contain previews, and
three/two-column sizes are implemented. The current 78 Flutter tests and 22 native
host tests pass; analysis retains only the 18 existing informational diagnostics,
and the Android debug APK builds. Coverage includes contain fitting and filled
preview bounds, filename visibility with folder labels and accessible names,
three/two columns, preference restoration, narrow toolbars, and keeping the
remembered image visible after display changes.

This display adjustment has automated verification only; no physical-device run
was performed. The Android 14 results above describe the earlier picker
validation. Crop and workout rendering were not changed.
