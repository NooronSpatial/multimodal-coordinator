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
