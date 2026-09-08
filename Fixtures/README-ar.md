# The Arabic fixtures (4u, AC-219, F-5 = B)

Two recordings, two numbers, because the person holding the phone speaks
Algerian Darja and every organ on the Arabic path — Whisper, Qwen3-4B,
Majed — does Modern Standard Arabic.

| file | what | reference |
|---|---|---|
| `ryad-ar-msa.wav` | ~30 s of MSA, READ, Ryad's voice | `bakeoff-reference-ar-msa.txt` — read verbatim |
| `ryad-ar-darja.wav` | ~30 s of Darja, SPOKEN naturally | `bakeoff-reference-ar-darja.txt` — Ryad's own transcription of what he said |

Format matches `ryad-en.wav`. The reference texts carry no tashkeel
(diacritics): Whisper does not emit them, and the Arabic normaliser
(AC-213) strips them anyway. Provenance: recorded by Ryad, 2026-09.
