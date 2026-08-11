import os

/// The pipeline's marks for Instruments (AC-45, D-026).
///
/// Thin by design and honestly un-unit-testable: nothing in a test can
/// observe an os_signpost. Verification is a field job — point Instruments
/// at a device and the intervals draw themselves. What the tests DO protect
/// is everything around the marks: the suite runs identically with the seam
/// present or absent.
///
/// Where marks may live is D-026 law: pump, session, engines. Never the
/// audio thread — the capture side's story crosses through its atomics.
public struct PipelineSignposter: Sendable {
    let poster: OSSignposter

    init(subsystem: String = "dev.nooron.MultiModalKit", category: String = "pipeline") {
        self.poster = OSSignposter(subsystem: subsystem, category: category)
    }

    /// A span you can carry across suspension points and store in state —
    /// begun now, ended wherever the story ends.
    public struct Span {
        let name: StaticString
        let state: OSSignpostIntervalState
    }

    // MARK: - synchronous work (the pump's poll)

    /// Wraps one synchronous unit of work — one drain, one VAD batch.
    public func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = poster.beginInterval(name, id: poster.makeSignpostID())
        defer { poster.endInterval(name, state) }
        return try body()
    }

    // MARK: - asynchronous work (a feed, a decode)

    /// Wraps one awaited unit of work — an engine decode, a chunk feed.
    public func measure<T: Sendable>(
        _ name: StaticString, _ body: () async throws -> T
    ) async rethrows -> T {
        let state = poster.beginInterval(name, id: poster.makeSignpostID())
        defer { poster.endInterval(name, state) }
        return try await body()
    }

    // MARK: - long stories (an utterance, a settle)

    /// Begins a span whose end lives somewhere else in time — stored in the
    /// session's state, ended at retire.
    public func begin(_ name: StaticString) -> Span {
        Span(name: name, state: poster.beginInterval(name, id: poster.makeSignpostID()))
    }

    public func end(_ span: Span) {
        poster.endInterval(span.name, span.state)
    }
}
