# 4y evidence — the CI runner starved by the deadline hammer (2026-09-16/17)

*What this is:* the fork sheet a review judge wrote after three skeptics
tried to refute the diagnosis "the 400-round deadline hammer starves the
3-core CI runner and two unrelated TTS tests die underneath it", from the
runner's own logs (four red runs: `ec128d4`, `3534fec`, `f39a0ce`,
`a1ec254`) and the source. Ryad ruled **A** on 2026-09-17 (D-111). Kept
as the evidence behind `ci.yml`'s two test steps. The "Housekeeping"
note at the end is stale: D-108 is committed.

## Fork: the 4y hammer starves the 3-core CI runner

First the picture. A "vCPU" is one virtual processor core of the CI machine. The "cooperative pool" is the small, fixed set of threads that Swift uses to run every `async` task: one thread per core, so 3 on the runner and 10 on this Mac. A task that never pauses keeps its thread.

```
THE RUNNER  (3 vCPUs = a 3-thread pool)          THIS MAC (10 cores)

t+0 s    777 tests start at once                   same
t+8 s    everything else has finished              everything finished by ~3 s

pool     [ producer ][ drain loop ][ collector ]   the same 3 hot tasks use 3 of 10 threads
         the hammer's three hot tasks, 400 rounds, 
         no pause while tokens are in the buffer   7 threads stay free

waiting  CONTROL poll ... margin poll ... speech row
         (no thread for 25-40 s)                   they get turns; slower, but green

t+15..44 s  hammer ends -> the three waiters wake
            the polls read the wall clock: far past their cap -> RED
```

Two words used below. A "poll" asks "is it done yet?" again and again (`Task.yield()` in a loop). An "event" is being woken once, when the fact happens. A "cap" is a time limit on a wait. A "regex" is a text pattern.

What all options share: no production code changes. The run loop already stops at the first token after the deadline (Sources/MultiModalKitMLX/MLXReplyGenerator.swift:352-364: `admitted` is nil past the flag, then `if dead { return nil }`), so the "production drains the buffer" idea is false and needs no ruling. The whole cost of the hammer lives in test doubles.

```
        touches                proof of the hammer          who can verify it, when
A  CI split   ci.yml + docs    unchanged, byte for byte     one CI push, this week
B  faucet     3 test files     shape changes; strength      CI only (MLX does not
                               becomes a MEASURED number    link on this Mac today)
C  serial CI  ci.yml, 1 flag   unchanged                    one CI push; cost unknown
D  gate       test file + CI   kept on CI, LOST from a      one CI push + docs
              + COMMANDS.md    plain local `swift test`
```

### Option A — CI only: the hammer runs alone, in its own test step

**What changes.** `.github/workflows/ci.yml` only (plus a D-entry and one line in docs/evidence/4y/README.md saying CI prints two summaries). The single `Test` step becomes two:

```yaml
      # THE HAMMER RUNS ALONE (D-111). Its 400 x 20,000-token rounds hold
      # every thread of this 3-vCPU runner (measured: ci-ec128d4,
      # ci-3534fec, ci-f39a0ce, ci-a1ec254 — two unrelated TTS tests died
      # underneath it). Same test, same 400 rounds; only the process changes.
      # The pattern is the test's ID (Module.Type/function), never its title.
      - name: Test (the suite, minus the hammer)
        run: swift test -Xswiftc -warnings-as-errors --skip 'MLXDeadlineTests/aTokenIsNeverSpokenAfterTheDeadlineTerminal'
      - name: Test (the hammer, alone)
        run: |
          set -o pipefail
          sysctl -n hw.ncpu
          swift test -Xswiftc -warnings-as-errors --filter 'MLXDeadlineTests/aTokenIsNeverSpokenAfterTheDeadlineTerminal' | tee "$RUNNER_TEMP/hammer.log"
          # A renamed test would match nothing, and SwiftPM only WARNS
          # ("No matching test cases were run", exit 0). This line makes
          # the step prove the hammer really ran and passed:
          grep -q 'four hundred deadlines against a firehose.*passed after' "$RUNNER_TEMP/hammer.log"
```

Keep `-Xswiftc -warnings-as-errors` on both calls, or the second call rebuilds with different flags (minutes). I left out `--skip-build`: it is verified in SwiftPM source but never exercised on the runner; without it the second call does a no-op incremental build that costs seconds. It can be added later.

**Proof.** Unchanged. Same binary, same function, same 400 rounds, same 20,000-token firehose, same 1 ms manual-clock deadline. The review's own hammer that caught 2 of 400 ran on a Mac with no neighbours, so "alone" is closer to the condition that found the race, not further. What A does NOT add: the hammer still never checks that tokens were in flight when the cut landed (it hopes so). That is the same today.

**Runner cost.** Step 1: about main's 8 s of test time (in every red log the rest of the suite was done within 1.4 s of the hammer). Step 2: package load plus the hammer alone on 3 vCPUs. **Unknown.** Known points: 2.4 s alone on this Mac's 10 cores; 22.5 s alone on a one-thread pool; 15-44 s on the runner with neighbours. The first CI run prints the number. Local: nothing changes; `swift test` and the 20x loop still run all 777 tests together.

**Risks.**
- A rename un-skips the hammer in step 1 (loud, CI red) and un-matches it in step 2 (silent without the grep). The grep uses the title as the runner's own log prints it (verified against the four red logs).
- The ID pattern was verified on this Mac's toolchain (it matched exactly 1 test from the built bundle; (review workspace) list-tests.txt:328) and by reading the 6.3.3 filter source (`String(describing: test.id).contains(regex)`). NOT exercised on the runner's toolchain. Low risk; the first run shows it.
- It isolates, it does not repair. The hammer keeps its runner-hostile shape; the next heavy test can starve the same victims. The two victims stay yield-polls with 4.6-6.8 s of an 8 s budget already used on green main (see the victims note).
- The hammer never again runs beside other MLX rows on CI; that interference is now only exercised locally.
- The hammer's suite has a 1-minute time limit; 44 s was 74% of it with neighbours. Alone it should be faster. If it is not, the step goes red loudly.

### Option B — Test-double fix: a chunked faucet, turned off at the cut, and the cut MEASURED

**What changes.** Three test files, no production code.
- `Tests/MultiModalKitTests/Mind/MLXReplyConformanceTests.swift`: a new `Plan.faucet(batch:batches:)` case: `batch` tokens in one tight loop, then one `await Task.yield()` and a `Task.isCancelled` check, repeated until cancelled or `batches` reached, then `holdUntilCancelled()` as today. Plus a `var yielded: Int` accessor.
- `Tests/MultiModalKitTests/Mind/MLXDeadlineTests.swift`: the hammer uses `.faucet(batch: 256, batches: 4_000)`; each round reads `producedBeforeCut = source.yielded` before `advance(by: 1 ms)` and counts `midStream += 1` when `heard < producedBeforeCut` (tokens were still in the buffer at the cut, so the drain loop was mid-stream); `#expect(midStream > 0)` and the count printed in the message.
- Optional, free: `MLXPressureDoubles.swift:219` sends "token N" facts only for the first 8 tokens (no test waits above "token 3": grep of `heard("token`).

**Proof.** 400 rounds kept, 1 ms cut kept, one terminal last kept. Two honest changes: today the drain loop is busy for ~100% of the pre-cut time (20,000 tokens pre-buffered); with the faucet it is busy while draining a batch and parked between batches, so some rounds land the cut on a parked loop and prove nothing for that round. The per-round hit rate of the old two-writer bug (2 of 400 in the review; 7 and 12 of 400 in commit 3932c36) falls by that dry-round share. In exchange the strength becomes a printed number every run instead of a hope, and `> 0` cannot flake. Sub-fork for Ryad: a floor (say 200 of 400) is a stronger guard but a statistical assertion on a slow runner.

**Runner cost.** Estimated 10-20x fewer lock operations (from ~64 million per run to ~3-5 million); every hammer task pauses at least every ~0.3 ms, so the pool is never held. Locally ~0.2-0.4 s instead of 3.2-6.6 s; on the runner an estimate of 1-3 s. **All estimates: nobody could run this on this Mac today.** Batch 256 is a guess; if `midStream` prints low on CI, batch 1,024 is the next step.

**Risks.**
- The producer paces itself with `Task.yield()`. It is bounded (batch cap, cancellation check, the round's own event caps), so it is not a wait-for-a-condition, but it is a yield loop in a double and this house has a scar there. The reviewer should say so in the comment.
- Cannot be shown red-then-green on this Mac (no Metal toolchain, so nothing linking MLX builds). The proof would come from CI runs only, and the strength number must be read from a real CI run before 4y is called done.
- It edits the regression guard's teeth. That is a ruling on the guard itself, not a CI tweak.
- On a crowded runner the first seconds may produce many dry rounds; the count tells, but a floor could flake.

### Option C — One flag: `--no-parallel` on the CI test step

**What changes.** `.github/workflows/ci.yml`, one line: `swift test -Xswiftc -warnings-as-errors --no-parallel`, plus a D-entry. Verified: the flag reaches the testing library (6.3.3 EntryPoint line 489: `if args.contains("--no-parallel")`), and locally three tests then ran strictly one after another. Note the help text says "(default: --no-parallel)"; that default is for the old XCTest path. The new library runs everything in parallel unless the literal flag is present, which is why 777 tests start within 100 ms in every log.

**Proof.** Unchanged; the hammer runs alone because everything runs alone.

**Runner cost.** Unknown and probably large: the suite becomes the SUM of every test's time. The logs cannot give that sum (their durations include queueing). Real-audio waits of 350-400 ms in many TTS rows plus the hammer suggest minutes, not seconds.

**Risks.** Serial CI hides interference between tests that a parallel run finds; CI stops contributing to the 20x parallel evidence; every future test pays for one hammer. A fallback, not a fix.

### Option D — Gate the hammer behind `MMK_HAMMER=1` and give it its own CI step

**What changes.** `Tests/MultiModalKitTests/Mind/MLXDeadlineTests.swift`: add `.enabled(if: ProcessInfo.processInfo.environment["MMK_HAMMER"] == "1", "...")` to the hammer (the same trait the repo already uses in MLXInstallSuspendTests.swift:25 and MLXPressureTests.swift:198; it prints a real "skipped" line). `ci.yml`: step 1 plain `swift test`; step 2 `MMK_HAMMER=1 swift test --filter ...` with the same grep guard. `COMMANDS.md` and the README's 20x rule must say the loop is now `MMK_HAMMER=1 swift test`.

**Proof.** Kept on CI. LOST from a plain local `swift test`: the one test that guards the one-writer fix no longer runs unless the variable is set. The live rows are gated because hardware may be absent; this would gate a test only because it is slow, which is the shape the house rules call hiding a shortcut.

**Runner cost.** Same as A.

**Risks.** A forgotten variable gives a green 20x loop that proves less. A third meaning of "gated" in the repo. Same rename risk as A.

### Not on the sheet, and why
- Production change ("stop iterating buffered tokens after the flag"): not needed, verified from source (MLXReplyGenerator.swift:352-364). Touching the one-writer loop would be a production ruling for no gain.
- Shrink-only variants (2,000-4,000 tokens; 100 rounds; cheaper bookkeeping): from the counts, none alone makes the runner's hole shorter than the victims' 3-10 s caps, and 100 rounds cuts one-run detection from 86.5% to 39.4% at a 0.5% hit rate. They can be folded into B, not chosen instead of it.

### One recommendation: A now, and bring B as the next fork with A's numbers

Why A first, in plain words:
1. **A is also the experiment.** Every skeptic asked for the same test: one CI run with the hammer skipped. Step 1 IS that run. If step 1 is green and step 2 passes, the diagnosis is settled and the branch is unblocked in one push. If step 1 is still red, the diagnosis is dead and we learned it cheaply.
2. **It is the only option this Mac can verify today.** Nothing that links MLX builds here (Xcode 27, no Metal toolchain). A changes no Swift file; B cannot be shown red-then-green locally.
3. **It keeps the review's net exactly.** The hammer is the guard for the two-writer race the review found. A does not touch its teeth.
4. **B is the better long-term shape, but it deserves numbers.** Step 2 prints how long the hammer takes alone on 3 vCPUs. If that number is small (under ~10 s), B's 10-20x saving buys little and its statistical assertion is not worth the scar. If it is large (30 s or more), B is worth its own ruling, with the `midStream` measurement as the reason to do it, not only the cost.

The honest cost of A: it isolates instead of repairing, and it leaves the two victims as fragile yield-polls (a separate debt, below). The D-entry should say both.

Housekeeping for whoever writes the D-entry: `DECISIONS.md` has an uncommitted D-108 in the working tree today (F-5/F-6, another session's work); the CI ruling takes the next free number and must not overwrite it. Nothing here was edited; this Mac stayed read-only.