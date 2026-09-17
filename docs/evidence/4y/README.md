# Milestone 4y — what was actually run

| file | what it is |
|---|---|
| `stability-2026-09-12.txt` | the 20× stability loop on the merged milestone, one line per run |

**The stability loop.** 20 runs, 20 passes, the identical `777 tests in
111 suites` every time, so there is no failing log beside this file. The
loop writes each failing run's FULL output before moving on.

**The memory rows.** INSTRUMENTS §68's table is read from the live MLX
rows in `Tests/MultiModalKitTests/Mind/MLXAdmissionLiveTests.swift` and
`MLXPressureTests.swift`, run with `MMK_MLX_MODEL` pointing at the 0.6B
weights. The same rows print `SKIPPED (no MMK_MLX_MODEL …)` in CI. The
0.6B's floor is 320 MB; the phone's 4B scales every number up.

**The phone demo.** Built for a real device against the merged branch
(`xcodebuild -destination 'generic/platform=iOS'`, unsigned):
`** BUILD SUCCEEDED **`, zero Swift warnings.

**What is NOT here, and is owed.** The phone: the 4B's numbers for the
three cuts, and the thermal curve with the mind generating every turn —
AC-266's second half, Ryad's gate. The Apple mind's live deadline row:
the on-device model reports `modelNotReady` on this Mac and the row skips
with that sentence.
