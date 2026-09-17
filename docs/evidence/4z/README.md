# Milestone 4z — what was actually run

| file | what it is |
|---|---|
| `plain-prompt-before.txt` | AC-272: the WHOLE prompt the MLX mind renders for §67's plain question with no table on the call and none on the generator — captured on the 0.6B (`mlx-community/Qwen3-0.6B-4bit`, snapshot `73e3e38`) BEFORE any commit of 4z touched `Sources/MultiModalKitMLX`, at `b0798db`. The first line is the vendor's token count; the text after the rule is the prompt decoded by the same tokenizer, byte for byte. |
| `red-2026-09-17-piece2-rows-against-the-shape.log` | Piece 2's rows (AC-271, AC-269's MLX half, AC-275 MLX, AC-278, AC-288's tag row, the ticket before the door) run against the SHAPE commit (`a78971d`): 31 tests, 33 issues — every judgment red before it was written. The rows that were green on arrival are named in the red commit and convicted by the three mutation logs below. |
| `red-2026-09-17-piece2-AC-278-under-mutation-M1-terminal-at-the-deadline.log` | AC-278's row under a mutation never committed: the run speaks `.finished(.deadline)` from the sleeper, at the deadline, while the body is parked (F-9 B's observable). Both order pins go red. |
| `red-2026-09-17-piece2-ticket-before-the-door-under-mutation-M2.log` | The before-the-door ticket pin under a mutation never committed: `execute`'s `guard !dead` BEFORE the door removed. A retired run knocks the door and the body runs. (Taken one lint fix before the commit: `MLXToolsPerCallTests.swift` line numbers in this log and M3's are one lower than the committed file's.) |
| `red-2026-09-17-piece2-confirmed-set-under-mutation-M3.log` | The confirmed-set row under a mutation never committed: the door is handed `confirmed: []` instead of the call's options. The person's yes never reaches the flagged tool. |
| `red-2026-09-17-piece2-hidden-band-under-mutation-M4.log` | AC-271's hidden-band row under a mutation never committed, on the GREEN rendering: the band rendered whatever `showsRange` says. The row was trivially green on the shape (no band rendered at all); this run shows it bites once properties render. |

**How the capture was made.** The row
`MLXPlainPromptTests` · "no table on the call, none on the generator:
the prompt is the bytes captured before 4z", run once with
`MMK_CAPTURE_PROMPT` pointing at the file:

```bash
export MMK_MLX_MODEL=~/.cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots/73e3e38d981303bc594367cd910ea6eb48349da8
MMK_CAPTURE_PROMPT=$PWD/docs/evidence/4z/plain-prompt-before.txt swift test --filter MLXPlainPromptTests
```

Without `MMK_CAPTURE_PROMPT` the same row COMPARES a fresh render
against this file and is red on any byte that moved. Without
`MMK_MLX_MODEL` it prints `SKIPPED (no MMK_MLX_MODEL …)`, as every
live MLX row does in CI.
