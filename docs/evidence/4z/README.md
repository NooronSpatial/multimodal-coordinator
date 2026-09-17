# Milestone 4z — what was actually run

| file | what it is |
|---|---|
| `plain-prompt-before.txt` | AC-272: the WHOLE prompt the MLX mind renders for §67's plain question with no table on the call and none on the generator — captured on the 0.6B (`mlx-community/Qwen3-0.6B-4bit`, snapshot `73e3e38`) BEFORE any commit of 4z touched `Sources/MultiModalKitMLX`, at `b0798db`. The first line is the vendor's token count; the text after the rule is the prompt decoded by the same tokenizer, byte for byte. |

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
