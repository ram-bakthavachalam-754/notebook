# Performance

## Native iOS typing

Validated on 2026-10-12 using the iPhone 17 Pro simulator. Previously each editor
change saved synchronously, reread the notes and journal collections, and loaded
all media while rendering on the main actor. The editor now keeps a local draft,
coalesces saves after 300 ms, and writes on a background task. A single writer
preserves newer text and revision heads when another edit arrives during a save.
Leaving the editor or backgrounding the app flushes pending changes. Collection
reads run off the main actor; library refreshes and periodic sync are deferred
while editing. Referenced media loads asynchronously without resetting the editor.

Two UI tests passed: offline notes/journal persistence across relaunch, and typing
with 1,000 seeded notes plus a one-second artificial save delay. The latter types
additional text during a pending save, immediately leaves the editor, then checks
the complete text after relaunch. The extra typing action took about 1.2 seconds
in the test log. This is an automation measurement, not a physical-device input
latency benchmark. Test fixtures and artificial delays are limited to Debug UI
test launches. A signed Release build was installed on the paired iPhone.
