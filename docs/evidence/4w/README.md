# Milestone 4w — what was actually run

The raw output of `bakeoff tool-spike` (the Mac half of AC-227 and
AC-228), kept here because the numbers INSTRUMENTS §67 quotes must be
traceable to a run someone can repeat. Release build, 2026-09-11, this
Mac; the phone numbers are Ryad's gate (§172c) and are not here.

| file | what it is |
|---|---|
| `tool-spike-Qwen3-0.6B-4bit.txt` | the 0.6B, no instruction, 5 runs per row — the shape the spike's live test proved |
| `tool-spike-Qwen3-4B-4bit.txt` | the 4B (the phone's model), no instruction, 5 runs per row |
| `tool-spike-Qwen3-0.6B-4bit-with-instruction.txt` | the 0.6B under the demo's spoken-reply instruction, 2 runs per row |
| `tool-spike-Qwen3-4B-4bit-with-instruction.txt` | the 4B under the same instruction, 2 runs per row |
| `stability-2026-09-11.txt` | the 20× stability loop on the merged milestone, one line per run |

How to repeat:

```
swift build -c release --product bakeoff
.build/release/bakeoff tool-spike --runs=5
.build/release/bakeoff tool-spike --runs=5 --model=~/.cache/huggingface/hub/models--mlx-community--Qwen3-4B-4bit/snapshots/<hash>
```

**What is NOT here, and is owed.** AC-227's "< 10 ms on the felt pause"
and AC-228's prices are phone criteria; this Mac shows the shape of the
cost, not the claim. The audio-thread allocation half of AC-227 is
`graph-probe`'s, not this instrument's.

**The stability loop.** 20 runs, 20 passes, the identical `701 tests in
98 suites` every time, so there is no failing log beside this file. The
loop writes each failing run's FULL output before moving on — a loop
that records only PASS/FAIL cannot find the race it exists to find, and
this project already paid for that lesson once (4t, run 13, log gone).

**The phone demo.** Built for a real device against the merged branch
(`xcodebuild -destination 'generic/platform=iOS'`, unsigned):
`** BUILD SUCCEEDED **`, zero Swift warnings. The demo carries the
Tools switch and the session stub; the phone run itself is Ryad's.
