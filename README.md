# MultiModalCoordinator

A high-performance coordination library for on-device AI streaming — built in
public, phase by phase, with every design decision logged and defensible.

**Phase 1 (in progress):** real microphone capture → lock-free ring buffer →
voice activity detection → clean provider seams. The core problem of this
phase: the boundary where the real-time audio thread meets Swift concurrency —
crossed exactly once, with zero locks and zero allocation on the hot path.

Work in progress. See [SPEC.md](SPEC.md) for the acceptance criteria and
[DECISIONS.md](DECISIONS.md) for the design decision log.
