# The phone session — 2026-09-29, Ryad's iPhone (D-123)

D-123 put the phone after the merge, in one session. What was taken, and
how it is known. Every row below is **Ryad's report**, given in the
conversation that built 5b. The rows marked "reported" carry no numbers,
and the phone's model and iOS version were not recorded for any of them.

| row | what it asks | result | how it is known |
|---|---|---|---|
| AC-323 — PROBE-R | the retry's re-ask on the real model | **met**: F-18 A held 3 of 3; kept (D-126) | the probe's own trace, pasted unedited: `probe-r-2026-09-29-iphone.md`, INSTRUMENTS §72 |
| AC-316, the device half | the demo runs on a device; the Settings tab shows how the local mind's warm ended (AC-312's demo half); built and signed in Xcode's own build | **done** | reported by Ryad: "The demo on the device … done" |
| 5a's AC-300, row 1 | start the mind's download, lock the phone five minutes, unlock — the percentage has moved | **done** | reported by Ryad: "5a's three phone rows … done" |
| 5a's AC-300, row 2 | kill the app mid-transfer, relaunch, tap again — it continues, with a range request rather than the whole file | **done** | the same report |
| 5a's AC-300, row 3 | the system relaunches the app in the background when the last file lands, and `ModelDownloads.handleEvents` calls the completion handler once | **done** | the same report |
| AC-315 | the diet app: turn two's first token against 3.4 s; twenty turns that call a tool every time one is asked for | **owed** — the first trace (2026-09-30) could not take it: no turn ran on a kept session | `ac315-trace-2026-09-30-build-278.md` |

**What this file does not hold.** No durations, byte counts or
screenshots for the device rows, and no phone model or iOS version for any
row — they were reported as done, and that is what is written. The Kokoro
signing failure seen once in a scratch build (5b, compile with signing
off) did not stop the demo from being built, signed and run from Xcode on
the device.
