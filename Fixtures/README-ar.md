# The Arabic fixture (4u, AC-219, F-5 = A by D-098)

One recording, Modern Standard Arabic — what Whisper, Qwen3-4B and Majed
all do. A Darja recording was planned (D-097 F-5 = B) and withdrawn by
Ryad (D-098); the MSA/Darja gap is not measured and not claimed.

| file | what | reference |
|---|---|---|
| `ryad-ar-msa.wav` | ~30 s of MSA, READ, Ryad's voice | `bakeoff-reference-ar-msa.txt` — read verbatim |

Format matches `ryad-en.wav`. The reference texts carry no tashkeel
(diacritics): Whisper does not emit them, and the Arabic normaliser
(AC-213) strips them anyway. Provenance: recorded by Ryad, 2026-09.
