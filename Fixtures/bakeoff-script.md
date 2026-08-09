# The bake-off script (D-025)

This paragraph is the reference transcript, written down BEFORE any
recording was made — the ground truth is known in advance, and the reader's
accent is the point of the experiment.

## Recording rules

One take, normal speaking pace, arm's-length distance, quiet room. No
retakes for stumbles — a real user does not get retakes either. Recorded
once per speaker and committed as a small mono WAV next to this file.

## Scoring rules

Word error rate is computed after normalization: lowercase, punctuation
stripped, numbers as words. The first inference of each engine is excluded
(CoreML graph compilation, measured separately as warm-up).

## The paragraph (read exactly this, top to bottom)

My name is Ryad and I am testing two speech engines on this device. The
audio travels through a ring buffer into a pump that cuts it into small
chunks of twenty milliseconds. When I stop speaking for a moment the voice
detector closes the utterance and the engine writes the final text. Good
transcription should survive an accent, a fast sentence, and a technical
word like latency, concurrency, or microphone. This paragraph has exactly
the same words every time, so the error rate is a real measurement and not
an opinion.
