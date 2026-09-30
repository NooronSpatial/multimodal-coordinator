# Milestone 5d — the fast voice: what was actually run

Every file here is raw output or a reading of it, named by date and piece.
"This Mac" is macOS 26.6 with Xcode 27 (Swift 6.4), run WITHOUT
warnings-as-errors (the known Xcode 27 drift); CI (Xcode 26, Swift 6.3.3,
warnings as errors) is the gate.

| file | what it is |
|---|---|
| `red-2026-09-30-a-the-turn-timeline-signals-cascade.log` | Piece 1's FIRST red run, on the skeleton. It found a flaw in the shared test helper `ToolSpikeTests.Signals`: after one wait timed out, every later wait in the same test failed at once (a waiter cancelled at its deadline terminated the one `AsyncStream` all waits shared). Green runs never time out, so it never showed. The helper was rebuilt (one waiter per wait). Kept because it is what happened. |
| `red-2026-09-30-b-the-turn-timeline.log` | Piece 1's red on the committed tests (after the helper was rebuilt and three rows were tightened): 10 rows red on their own point, 6 guards green, ToolSpikeTests green on the new helper. |
| `api-diff-2026-09-30.txt` | AC-340: `Scripts/api.sh` at tag 0.5.0 against piece 1's green code — additions only (the two timeline types and the two default hand-offs on `LatencyReporter`). |
| `mutations-2026-09-30-piece1-M52-M60.log` | Piece 1's mutations: eight of nine killed; M60 (a second clock reading) survives as a belt, documented beside its line. M54's first verdict (SURVIVED) is FALSE and kept: the mutation as written trapped Swift's exclusivity check, the process printed no summary, and the old runner counted that as a survivor — the runner now says NO VERDICT; written legally, M54 is killed. |
| `red-2026-09-30-c-the-silence-meter.log` | AC-341's pure half, RED on the skeleton (`feed` does nothing): 3 rows red, 2 guards green (the edges; quiet is not silence). |
| `mutations-2026-09-30-piece1-M61-M65-the-meter.log` | The SilenceMeter's mutations: five of five killed. M65 needed a row added after green (the longest pause of ANY length), because no row had pinned it. |
