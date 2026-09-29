# Milestone 5c — what was actually run

"This Mac" is macOS 26.6 with Xcode 27 (Swift 6.4), run WITHOUT
warnings-as-errors (the known Xcode 27 drift); CI (Xcode 26, Swift 6.3.3,
warnings as errors) is the gate.

| file | what it is |
|---|---|
| `red-2026-09-29-the-typed-turn-failure.log` | The rows (AC-324…AC-329, and the seven re-pinned string rows) against a skeleton that changed the TYPE (`generationFailed(ReplyFailure)`) and not the judgment (every failure flattened to `.engine(<its words>)`): the typed rows and the admission row red; the foreign-error, pass-through and six `.engine` rows green as guards. |
| `mutations-2026-09-29-M43-M47.log` | Five mutations, five killed: mid-stream flattened (M43), at the open flattened (M44), a caller's error made `.unexplained` (M45), a `TurnFailure` at the open wrapped again (M46), the health road carrying another value (M47). M45 and M46 show the teeth of the guard rows that were green at red. |
| `stability-2026-09-29.txt` | The 20× loop: the whole suite, one line per run, each capped at 15 minutes under a pseudo-terminal, a failing run's full output kept beside it. |
| `stability-2026-09-29-run13-FAILED.log` | Run 13's full output — **the loop was 19 of 20**. The one failure is NOT in 5c's code: `WhisperInstallTests` "a stopped transfer … resumes next time" (5a). The resume failed with `NSPOSIXErrorDomain Code=2` from the background download daemon: the partial file its resume data points at was gone. Reading the downloader then showed a real 5a gap: a RESUMED task that fails keeps its stale resume data (it is removed only when a file lands, or on a delete). *Corrected by measurement (§222, D-131):* a cleanly lost partial is refetched by the system itself, so "every later attempt fails the same way" holds only for resume data nothing can read; run 13's POSIX 2 was a race inside the daemon. |
| `red-2026-09-29-the-stale-resume.log` | §222's rows (AC-331…AC-333) on 5a's downloader, measured first: the cleanly lost partial PASSED (the system refetches it — the premise corrected, D-131); unreadable resume data and "once, never a loop" red; fresh resume data kept (a guard). |
| `mutations-2026-09-29-stale-resume-M48-M51.log` | §222's mutations: M48 (restart despite fresh data) and M51 (never marked from resume) killed; M49 (no once-guard) and M50 (stale data left by the restart) survive as BELTS, each documented beside its line. |
| `stability-2026-09-29-stale-resume.txt` | The 20× loop on the fix branch (5c + §222): 20 of 20 at `979 tests in 141 suites`, no failing log. |
