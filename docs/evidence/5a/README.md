# Milestone 5a — what was actually run

Model downloads: progress on every engine, a transfer that survives the
background, a delete that removes what was written. Spec §199–§206,
rulings D-114.

Every file below was produced by a command in this repository, on Ryad's
Mac (macOS 26.6.1, Xcode 27, Swift 6.4) unless the row says otherwise.
The loopback rows move real bytes over a real socket against a server
that COUNTS; the `bakeoff downloads` rows move real bytes from the real
Hugging Face.

## The probes — measured before a line was designed

`probes/README.txt` has the machine and the server. These four are the
facts §199 rests on, and three of them ruled a fork.

| file | what it is |
|---|---|
| `probes/probe1-async-on-background-session.swift` · `probe1.out.txt` | **Fact 1.** The vendors' own background switch cannot work on this OS: the async `download(for:)` convenience on a background `URLSession` raises `NSGenericException` — *"Completion handler blocks are not supported in background sessions. Use a delegate instead."* — and the process dies. This is why F-3 = A (a downloader this library owns) rather than "flip the vendor's flag". |
| `probes/probe2-delegate-cancel-resume.swift` · `probe2.out.txt` | **Fact 2.** A background session WITH a delegate works, and resume works: 8 MB cut at 3.74 MB → 7 611 bytes of resume data → `Range` → `206` → the file complete. F-4 = A's mechanism, before any of it was written. |
| `probes/probe3-reentry-new-process.swift` · `probe3.out.txt` | **Fact 3.** A NEW process picks up a transfer the old one started: process A enqueued and exited after 0.5 s; process B, 2 s later, saw the task (its description intact) and received the finished file. The relaunch path, testable on a Mac. |
| `probes/hfprobe-background-session-real-hub-file.swift` | Taken later, to name a failure the demo found: the same real Hugging Face LFS file on a background session **on this Mac** answers `200`, 243 bytes. It is the control that proves the simulator — not the URL, not the redirect, not the library — is what fails. |
| `probes/rangeserver.py` | The probes' server: `Range` → `206`, `ETag`, `Accept-Ranges`, a settable delay per 64 KB chunk. |

## The reds — every judgment that failed before it passed

| file | what it is |
|---|---|
| `red-2026-09-20-piece1-downloader-absent.log` | Piece 1's rows against a `ModelDownloader` that did not exist yet: the build itself red, which is the first red a new type can have. |
| `red-2026-09-20-piece2-kokoro-installed-disagrees.log` | Kokoro's first run: 4 of 6 red. The downloader saw both files COMPLETE (no second request) while `isInstalled()` compared against the STATIC sizes — two owners of one truth. `KokoroWeights.Source` became the only owner; green on the next run. |
| `red-2026-09-22-piece3-under-mutation-M1-join-recheck-M2-cancel-discards.log` | Piece 3's rows under two mutations never committed: **M1** the join's after-the-await re-check removed (the second caller gets `couldNotComplete` over a directory somebody else finished); **M2** D-106's cancel-discards-the-partial rule put back (the seam's cancel row goes red). Both convict; both reverted. |
| `red-2026-09-22-piece3-delete-mid-transfer-scratch-reappears.log` | A delete during a transfer left the scratch RECREATED with one small file in it: a task whose bytes had all arrived was past cancelling, and its landing arrived after the fetcher removed the directory. Fixed by telling the relay BEFORE cancelling; a landing for a discarded destination now dies with its temporary file. |
| `red-2026-09-22-piece3-loop-run3-kokoro-truncated-row-hung-60s.log` | A row hung for its full minute in loop run 3 of 14. A re-`ensure` immediately after a landing ADOPTED the old task — its completion had not arrived, so `getAllTasks` still listed it — and that completion then cleared the file with no landing to follow. Every relay event now names its task; a landed task is never adopted nor heard again. 14 loop runs green after. |
| `red-2026-09-22-piece3-full-suite-run2-network-silence-overheard-the-listing.log` | The full suite red on `NetworkSilenceTests`: the mind's listing went through `URLSession.shared`, which the AC-252 recorder overhears, so eight loopback listings were reported as a neural-voice load's leak. The listing now has its own ephemeral session (`HubTree.session`). |
| `red-2026-09-22-piece4-under-mutation-M3-tokenizer-dropped.log` | Whisper's rows under a mutation never committed: the plan fetches the MODEL repository only. Four assertions red — the tokenizer is a separate repository, and the vendor's tokenizer load is local-FIRST but not local-ONLY, so a model fetched alone loads by quietly reaching Hugging Face. |
| `red-2026-09-22-piece5-neural-sizes-measured-by-hand-were-wrong.log` | The live size row convicting **my own measurement** before it shipped: the neural voice's pinned sizes were taken from download patterns reconstructed by hand (`speech_decoder` at `W8A16`; the vendor's default is `W8A16-multifunction`), out by 474 698 B on the 0.6B and ~113 MB on the 1.7B. SPEC §118's lesson: ask the vendor. |

## The live and the measured

| file | what it is |
|---|---|
| `live-2026-09-22-piece4-whisper-measured-sizes.log` | `MMK_LIVE_HUB=1 swift test --filter WhisperInstallLiveTests` against the real repositories: base 149 484 585 B, small 489 252 581 B, both matching `WhisperSizes.measured`. Opt-in, so CI stays hermetic; it exists to go red the day either repository is re-converted. |
| `instruments-70-downloads-2026-09-22.log` | INSTRUMENTS §70's table, raw: `swift run bakeoff downloads` — Whisper base 149 MB in 14 132 ms (10.6 MB/s), Kokoro 328 MB in 14 269 ms (23.0 MB/s), the 0.6B mind 351 MB in 13 732 ms (25.6 MB/s), the exact size question in 135 ms against §66's 3 388 ms, deletes 17–72 ms, every row `gone` afterwards. Real Hub, scratch root, deleted after. |
| `instruments-70-resume-join-counts-2026-09-22.log` | The two numbers only a counting server can give: **resume** — a 2 097 152 B file cut at 262 144 B sent 2 293 760 B across both attempts, 9.4 % overhead, one range request; **join** — two callers, 1 request, 524 288 B for a 524 288 B file. |
| `simulator-2026-09-22-background-session.md` | What running the demo found: the iOS Simulator has no background transfer daemon (every task fails at once with `NSURLErrorDomain Code=-1`), measured in both directions, and the foreground fallback that produced. It also lists the three phone rows nobody but Ryad can take. |
| `models-screen-2026-09-22.png` | The demo's Models screen on an iPhone 17 simulator: four rows through `any ModelBacked`, each with the size before the tap, a byte percentage and a Delete. |

## A note on one commit message

`eddc7f5`'s body lost three words: the message was written with backticks
around `swift run bakeoff downloads`, the shell evaluated them, and the
command name vanished from the line describing the new instrument. The
history is not rewritten for it — the commit stands as it landed, and
this sentence is the correction. The instrument is
`swift run bakeoff downloads` (`Sources/Bakeoff/Instruments/Downloads.swift`).
