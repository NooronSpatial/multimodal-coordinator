import MultiModalKit

/// A thermometer under the test's thumb: `push(_:)` changes the device's
/// "temperature" whenever the script says so (AC-49's sparring partner).
public final class ScriptedThermalProvider: ThermalStateProviding, @unchecked Sendable {
    private var continuation: AsyncStream<ThermalState>.Continuation?
    private var state: ThermalState
    private let stream: AsyncStream<ThermalState>

    public init(initial: ThermalState = .nominal) {
        self.state = initial
        var handle: AsyncStream<ThermalState>.Continuation!
        self.stream = AsyncStream { handle = $0 }
        self.continuation = handle
    }

    public var current: ThermalState { state }

    public func transitions() -> AsyncStream<ThermalState> { stream }

    /// The script's hand on the thermometer.
    public func push(_ new: ThermalState) {
        state = new
        continuation?.yield(new)
    }

    /// The device "ends" — the provider's stream finishes.
    public func finish() { continuation?.finish() }
}
