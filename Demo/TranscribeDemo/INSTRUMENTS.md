
## 52. The cold that would not come — the surviving ❄ report, the Mac's corroboration, and D-075

The §51 fix held: the ❄'s next run (Ryad's phone, the 4n field session)
kept its cache-clear report. The report was worth keeping, because it
refuted the design's own premise.

### The surviving report — Caches does not hold the cache

The clear found NOTHING to delete, and the neighbourhood line — built
for exactly this moment — named what the app's Caches actually holds:
com.apple.dyld entries, speech assets, the app's own bundle id, and
huggingface. No com.apple.e5rt, no com.apple.CoreML, no
com.apple.mlcompiler. D-074's control was pointed at the right kind of
directory on the wrong side of the sandbox wall: on iOS, the compiled
plans this app pays 64.8 s for (§30) are not kept where the app can
reach them.

### The Mac's corroboration, measured 2026-08-26 on this machine

- `~/Library/Caches/com.apple.e5rt.e5bundlecache` EXISTS at USER level
  — outside any app container. It held **0 bytes** at survey time: the
  OS fills and empties it on its own schedule. Both facts point the
  same way — the e5rt cache belongs to the system, not to the app that
  triggered the compile.
- The Mac's $TMPDIR held no e5rt/CoreML/mlcompiler staging at all. What
  it DID hold: ten-plus leaked `cold-*` roots from this project's own
  test fixtures — `makeContainer` never cleaned up after itself. Fixed
  with the D-075 work; the instrument that surveys tmp/ was itself
  littering tmp/.

### The ruling, and the code it changed

**D-075 (route A):** the survey extends to the app's `tmp/` — the one
cache-plausible container directory never yet looked at — and the
ruling carries its own ending: an empty tmp/ falls through to C with no
new fork. `CompiledPlanCache` now walks a list of directories, every
entry says WHERE it was found, absence names EVERY neighbourhood
separately, and a directory the control cannot read says "unreadable or
absent" instead of posing as empty (each rule pinned by a test, each
test proven killable by its mutation).

### What the next ❄ run decides — AC-172, still owed

Two outcomes, both terminal:

1. **tmp/ holds a compile cache** → the clear deletes it, the probe's
   fresh voice load IS the cold number, recorded here with its
   configuration.
2. **tmp/ holds nothing** → C by D-075: cold is system-owned, §30's
   64.8 s stands as the recorded cold number, and AC-172 closes with
   the honest line that the app cannot reproduce cold on demand — the
   report's "tmp holds: [...]" line is the evidence that we looked.
