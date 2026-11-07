# Local background timer integration

This directory contains the runtime source and audio assets from
`background_hiit_timer` 1.2.3, distributed under the included MIT license.
OpenHIIT uses this local package so custom audio works in the background service
as well as in the foreground preview.

Local changes add private media references, explicit interval stage metadata,
serialized cue replacement, pause/skip/restart cancellation, and a separate silent
keepalive player. Existing interval timing thresholds and restart behavior are
retained. The temporary service database is upgraded to version 2 for stage
metadata. `path_provider` resolves media files independently in the service
isolate.

See [Android build instructions](../../docs/android-build.md) for building the app
and running the isolated device tests.
