# Milestone 4x — what was actually run

The house rule is that a claim is worth what its evidence is worth, so the
runs behind 4x's definition of done live here rather than only in a commit
message.

| file | what it is |
|---|---|
| `stability-2026-09-10.txt` | the 20× stability loop on the merged milestone, one line per run |
| `install-size-2026-09-10.txt` | `bakeoff install-size` against the real repository — the raw output behind INSTRUMENTS §66 |

**The stability loop.** 20 runs, 20 passes, and the same count every time:
`Test run with 659 tests in 89 suites passed`. Zero failures, so there is
no failing log beside this file. That absence is the point — the loop
writes each failing run's FULL output to `loop-fail-<n>.log`, because a
loop that records only PASS/FAIL cannot find the race it exists to find.
That lesson cost this project a flake it can never explain (milestone 4t,
run 13 of 20, log gone).

**The size probe.** Nine files, 2 278 969 756 bytes, asked in 3 388 ms,
and zero files landed in the target directory — AC-246 proven against the
real repository rather than a fake. The number drifts when the model is
re-quantised; the date in the filename is why it is written down.

**What is NOT here, and is owed.** The phone gate — one run of the demo on
a real device — is Ryad's, and so is the on-device morning that Aura's own
milestone needs. This Mac cannot answer either.
