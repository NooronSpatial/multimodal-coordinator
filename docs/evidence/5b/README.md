# Milestone 5b — what was actually run

Every file here is raw output or a reading of it, named by date and piece.
"This Mac" is macOS 26.6 with Xcode 27 (Swift 6.4), run WITHOUT
warnings-as-errors (the known Xcode 27 drift); CI (Xcode 26, Swift 6.3.3,
warnings as errors) is the gate. The Apple model reports `modelNotReady`
on this Mac, so every Apple row drives the fake session maker.

| file | what it is |
|---|---|
| `red-2026-09-23-piece1-a-session-per-reply.log` | Piece 1's first red: the AC-303/304 rows against the keeper's skeleton, which still made a fresh session per reply. |
| `red-2026-09-23-piece1-b-nine-rows-against-the-skeleton.log` | Piece 1's nine rows (AC-303, AC-304, AC-306's core, AC-309) against the keeper's skeleton. |
| `mutations-2026-09-23-piece1-M1-M4.log` | Piece 1's mutations. M4 — the cancellation check after the stream — survives: a belt, documented beside the line. |
| `red-2026-09-24-piece2-a-tool-call-is-a-tool-call.log` | Piece 2 (AC-305, AC-311, D-119): tool calls kept and replayed typed. |
| `mutations-2026-09-24-piece2-M5.log` | M5: a finished turn written without its tools re-seeds every tool turn. |
| `red-2026-09-24-piece3a-when-a-session-ends.log` | Piece 3a (AC-306 through the coordinator, AC-307, AC-310). |
| `mutations-2026-09-24-piece3a-M6-M8.log` | Piece 3a's mutations. |
| `red-2026-09-29-pieceR-the-reply-retry.log` | Piece R (§213, AC-317…AC-322) against its skeleton: 9 rows red (7 retry, 2 failure-table); 4 guard rows green, one of them seven cases. |
| `mutations-2026-09-29-pieceR-M9-M21.log` | Piece R: 12 of 13 killed; M19 (the cancel belt in the retry check) survives by design, documented. |
| `red-2026-09-29-piece3b-the-bound-and-the-wall.log` | Piece 3b (AC-308, F-12 C, F-22 B): 4 rows red, 2 guards green. |
| `mutations-2026-09-29-piece3b-M22-M30.log` | Piece 3b. First run: M24 SURVIVED — a real gap (the window must match, not fit); a row was added; the rerun killed it. Both runs inside. |
| `red-2026-09-29-piece4-the-warms-end.log` | Piece 4 (AC-312, F-21 B): 7 rows red, 2 guards green; the live row skips here. |
| `mutations-2026-09-29-piece4-M31-M42.log` | Piece 4. M32 HUNG the first run through a test helper (killed by hand; the runner's "SURVIVED" for it is wrong and marked so); the helper was fixed and the rerun killed M32 and M42 in ~10 s. M40 is unreachable on this Mac, documented. |
| `instruments-71-session-2026-09-29.log` | INSTRUMENTS §71: `swift run bakeoff session` — what one turn prefills, fresh and kept, in characters; the vendor's token count refused here. |
| `ci-hang-2026-09-29.md` + `ci-hang-2026-09-29-run-36579409889.log` | One CI run that never finished (piece R's push): the raw log and an honest reading of it — not reproduced, not yet explained. |
| `strict-pool-2026-09-29-one-thread.log` | The whole suite with a one-thread cooperative pool (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), run while reading the CI hang: green — no task blocks a thread while it waits on another. |
| `probe-r-2026-09-29-iphone.md` | PROBE-R on Ryad's iPhone (AC-323, INSTRUMENTS §72): three trials of the fault injected after the tool, then the re-ask three ways. F-18 A held 3 of 3; C was faster. Pasted from the demo's share sheet, unedited. The phone's model and iOS were not recorded by the probe then; its share text records them now. |
| `phone-session-2026-09-29.md` | The phone session so far (D-123): PROBE-R (its own file), the demo on the device (AC-316), and 5a's three phone rows (AC-300) — as Ryad reported them: done. No numbers, phone model or iOS were recorded, and the file says so. AC-315 is still owed. |
| `ac315-trace-2026-09-30-build-278.md` | The first TestFlight trace for AC-315 (the diet app's build 278, on 0.4.0), as pasted, with the library's reading: every measured turn began in a new session after a barge (`memoryChanged` — the model had finished, the speech was cut), so AC-315 is still owed; tools were called when asked; no retry fired. |
| `stability-2026-09-29.txt` | The 20× loop: the whole suite, one line per run, each run capped at 15 minutes and run under a pseudo-terminal so a hang would show which tests were running. A failing run would keep its full output beside it. |
