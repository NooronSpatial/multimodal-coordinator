# The AI Runtime — progress

*Where the AI Runtime stands, on one page: what it does today, what its
name still promises, what is known to be missing, and what is owed. This
page only POINTS. Every row names where its fact is proven — a SPEC
section (what was promised and measured), a D-entry (who ruled, and why),
an evidence file, or a tag note (`git show <tag>`).*

**As of 2026-10-06** · `main` at `f11dca4` · latest tag **0.5.0**
(`e82533d`) · **milestone 5d — the fast voice** (D-132), on
`milestone/5d-fast-voice`: piece 1, the turn timeline, is measured on the
Mac and on Ryad's phone (INSTRUMENTS §73, §73b) — the felt pause is ~3.3 s
to the first word, and one reply was cut by its own echo. Piece 2, the voice
(D-137, D-138), is built and measured on the Mac (§74): the quiet before the
first word 325 → 40 ms, no silence over 300 ms inside any answer; Ryad's ear
kept every number, and on his phone (§74b) the first sound halved (1 337 →
660 ms) and the felt pause to the first word fell from ~3.3 to 2.3 s. Piece 3, the echo (D-140), is built and checked on the Mac (§75): a barge proves itself by staying LOUD 320 ms — the diet app's R-4 — decided 280 ms sooner than before; its phone row is owed.
The download daemon's flake keeps "20 of 20" open (SPEC §233, D-139).

## The picture

```
 THE AI RUNTIME TODAY (0.5.0)                 WHAT THE NAME STILL PROMISES (D-115)
 ┌──────────────────────────────────────┐     ┌───────────────────────────────────┐
 │ ear ──▶ mind ──▶ mouth               │     │ vision           it cannot see    │
 │   a voice conversation (phases 1–4)  │     │ a model router   no mind chosen   │
 │   one front door, AIRuntime (4t)     │     │                  for the task     │
 │ the mind:                            │     │ permissions      a yes per tool,  │
 │   tools the app grants (4w, 4z)      │     │                  by NAME only     │
 │   one session per conversation (5b)  │     └─────────────────┬─────────────────┘
 │   typed failures (4v, 5c)            │                       ▼
 │ the weights: install, download,      │           the rename, ONCE, at a major
 │   resume, delete (4x, 5a)            │           version: the package and the
 │ safety: admission, heat, memory      │           modules become the AI Runtime
 │   pressure, a deadline (4y)          │
 └──────────────────────────────────────┘
```

Built so far: phases 1–3, milestones 4a–4z, 5a–5c, and six tags
(0.1.0 … 0.5.0). What each tag gave is in [README.md](README.md)'s Status
table; the API each one added is in
[docs/INTEGRATE.md](docs/INTEGRATE.md) § "Which tag has what".

## How to read the status words

| word | means |
|---|---|
| **done** | merged, tested, the 20× loop green; the "where" column says where |
| **partial** | part of it is built; the row says which part is missing |
| **open** | known and written down, not built |
| **parked** | stopped by a ruling; the ruling says when it comes back |
| **owed** | a measurement or a proof not taken yet |
| **not opened** | a question nobody has asked Ryad to rule |

## 1. The road to the name (D-115)

The package and its modules are renamed to the AI Runtime once, at a major
version, *"when the runtime can do what the name claims"* (D-115). The
type `AIRuntime` took the name early, as a direction and not a claim
(D-093 F-5); its own doc lists what it cannot do yet
(`Sources/MultiModalKit/Runtime/AIRuntime.swift`). The Runtime became the
work when Arabic was parked (D-100).

| capability | status | where |
|---|---|---|
| a voice conversation: ear → mind → mouth, turn-taking, barge-in | **done** | phases 1–4; ARCHITECTURE § "The spine" |
| one front door that owns the order | **done** (4t) | D-093; ARCHITECTURE § "The front door" |
| tools the app grants | **done** (4w the spike, 4z the contract) | D-110; ARCHITECTURE § "The tool contract (4z)" |
| one mind session per conversation | **partial** — the Apple mind has it (5b); the MLX mind keeps none (§4) | D-116; ARCHITECTURE § "One mind session per conversation (5b)" |
| **vision** — the mind can see | **open** — no spec yet | `AIRuntime.swift`'s doc; D-115 |
| **a model router** — the right mind for the task | **open** — no spec yet | the same |
| **a permission layer** | **partial** — one yes per call for a flagged tool (4z), bound to the tool's NAME, not its arguments (§2) | `AIRuntime.swift`'s doc; D-110 F-10 B-ii |
| the rename: repo, package, modules, both apps | **waits** for the three above | D-115 |

## 2. Gaps inside what exists

| gap | what goes wrong | status | where |
|---|---|---|---|
| the conversation feels slow — after the person stops talking, when they interrupt, inside the answer, on the first turn — in every setup Ryad tried | measured on the Mac in his setup: the felt pause is 2.0–2.4 s warm (① 300 · ② ~140 · ③ 500 · ④ ~850 · ⑤ 300–500), the mind starting only after 800 ms of waiting; a silence over 300 ms inside every answer; a cold first turn of 13–14 s (the ear's first model load); an interruption needs 600 ms of voice | **open** — measured; the fixes are next, each a fork (SPEC §229) | D-132; SPEC §231; INSTRUMENTS §73 |
| `AIRuntime.run` never returned when its observer returned on its own while a health seam was attached | the thermal watcher ends only when cancelled, and nothing cancelled it | **fixed** (2026-10-01): the runtime cancels what its stops cannot end | D-135; SPEC §232 |
| the ear returns empty text for some short real sentences | those turns are never answered (3 of 20 per Mac run) | **open** | INSTRUMENTS §73 |
| a barge while a tool's body runs drops that tool's record | the write stands, but the memory never learns it, so the next turn's model does not know it happened | **open** | SPEC §214 "Known limits" |
| the yes binds to the tool's name | after a yes, the model's next call of that tool runs with whatever number it writes; B-iv (name plus arguments) would close it | **open** — ruled and recorded as a hole | D-110 F-10 B-ii; ARCHITECTURE § "The tool contract (4z)" |
| a tool cannot take a list or an object | the door refuses it | **open** — a 4z non-goal | SPEC §194 |
| no loud fallback where the audio graph cannot start | such a device has no working fallback arrangement | **open** — AC-123 NOT MET, carried openly | SPEC AC-123 |
| the scripted test mind never sends `.toolRan` | a caller testing tool records through the coordinator with `ScriptedReplyGenerator` sees none | **open** | SPEC §214 "Known limits" |

## 3. Owed — proof not taken yet

| row | what it needs | how it will be taken | where |
|---|---|---|---|
| AC-315 | turn two's first token on a KEPT session; twenty turns that call their tools | the diet app's next TestFlight trace, a conversation with no barge — the first trace (2026-09-30) could not take it | SPEC §214; D-127; `docs/evidence/5b/ac315-trace-2026-09-30-build-278.md` |
| the resume path on 0.5.0, on a phone | the stale-resume fix (§222) was measured on a Mac only | the diet app's next build: a download killed by swiping the app away. It runs the resume path on 0.5.0; it may not fire the fix's own trigger | SPEC §223 |
| 4z on the phone | AC-269's Apple half, AC-276's live ending, AC-272 (c), AC-281's phone rows, AC-286's per-turn line | the Apple model on a phone | SPEC §198 |
| heat, after the talk | the cool-down curve after stopping; the stop latency from a barge to silence (AC-102) | the phone | README "Open" |
| Kokoro on the phone | its clean result (no silent gaps, WER 0.000) is a Mac number | the phone | INSTRUMENTS §57; D-084 |
| the Apple mouth's echo leak | never timed | the phone | INSTRUMENTS §45 |
| `whenWarm()` live, and mutation M35 | real weights (`MMK_MLX_MODEL`) | a Mac with the model | SPEC §214 |
| graph-probe's control case | does not reproduce on a plain Mac engine | the phone | INSTRUMENTS §20 |
| the Qwen3 voice's batching pin | untested; it rests on reading TTSKit's source | — | README "Open" |

## 4. Parked by a ruling

| what | ruling | comes back when |
|---|---|---|
| the MLX mind's kept session (a KV cache across turns) | D-116 F-5 B | its own milestone, with its own memory measurement — 2.2 GB of weights leave little room to guess |
| Arabic, and other languages | D-100 | not dated |
| per-utterance language detection | D-097 F-1 | once every organ takes a language at all |

## 5. Not opened

| question | why it came up | where |
|---|---|---|
| keep the session across a barge that cut only the speech? | every such barge starts the next turn in a new session (D-117, as built), so the saving depends on short replies; the diet app is shortening its replies first | `docs/evidence/5b/ac315-trace-2026-09-30-build-278.md` |

## 6. The method's own debt

| debt | status | where |
|---|---|---|
| one CI run that never finished | **open** — not explained, not seen again | SPEC §214; `docs/evidence/5b/ci-hang-2026-09-29.md` |
| a time limit on CI (`timeout-minutes`) | **proposed, not ruled** | — |
| about ten test waits still poll (`Task.yield()` in a capped loop) where the rule is events | **open** | the TTS, transcription, pump and diagnostics tests |
| 5a's downloader test bench flakes under parallel load (5c's run 13; 5d's run 16, a bad file descriptor in its setup) | **hunted** (D-135): two bench defects proven and fixed (D-136); after them, 59 of 60 — the bad descriptor and the empty helper words not seen again, causes not proven; the download daemon's resume family recurs (3 sightings) — Ryad's ruling | SPEC §221, §231, §233 |
| real-audio rows of `PlaybackLeadStrandTests` flake on CI only (started, never finished within 3 s) | **open** — 3 sightings (`8952ee8`, `90dc27d`, `1a30ecd`), none in 80 local runs; corrects the guess in `10d6dae` | SPEC §240 |
| three copies of the old `Signals` test helper (one timed-out wait ends every later wait) | **open** — the ToolSpike copy is rebuilt | `AIRuntimeTests`, `AdmissionTests`, `ReplyContractTests` |
| teach-back rows | **owed** (e.g. 4z's AC-287); 5b's was skipped by ruling | SPEC; D-127 |
| stale lines in the docs | **open** — README's phase table stops at 4h, and its "two real mouths" paragraph predates Kokoro (D-084); ARCHITECTURE's front-door paragraph still says the runtime "cannot call a tool", false since 4z | README; ARCHITECTURE § "The front door" |

## 7. The apps that use it

| app | what it asked | where it landed |
|---|---|---|
| the diet app | the reply retry (R-1) and a name for the vendor's unnamed failure (R-2) | 5b, tag 0.4.0 — SPEC §213 |
| | a typed turn failure (R-3) | 5c, tag 0.5.0 — SPEC §215–§221; its AC-6…AC-9 checked by the diet app on 2026-09-30: all four met, no new ask |
| Aura | the mind's text contract (slice 1) | 4v, tag 0.1.0 |
| | the install | 4x, tag 0.2.0 |
| | admission, heat, memory pressure, a deadline (R1–R3, R7) | 4y, tag 0.3.0 — SPEC §186 |

## How this page stays true

- **Every row points to where it is proven.** A row with no pointer is a
  wish, and a wish does not belong here.
- **A status changes only on evidence, in the same PR that brings it** —
  a milestone's PR, a tag's docs follow-up, a phone result.
- **The order is Ryad's.** "Next" says *not ruled* until a D-entry rules
  it; a builder's suggestion is marked *proposed*.
- **Numbers are not typed here.** The counts are in ARCHITECTURE's
  generated shape block, the API in INTEGRATE's generated appendix.
- **Update the "As of" line** whenever a row changes.
