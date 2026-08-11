import Foundation

/// The device's temperature, as four honest words (D-027).
public enum ThermalState: Sendable, Equatable, Comparable {
    case nominal, fair, serious, critical
}

/// The seam (AC-49): the pipeline never asks the device directly — it asks
/// whoever was injected. The real provider wraps ProcessInfo; tests script
/// transitions by hand, so no test ever depends on a room's temperature.
public protocol ThermalStateProviding: Sendable {
    var current: ThermalState { get }
    /// State changes, from subscription onward. Ends when the provider does.
    func transitions() -> AsyncStream<ThermalState>
}

/// The real edge, deliberately thin (like MicrophoneSource): wraps
/// ProcessInfo's notification. Not unit-tested — there is nothing of ours
/// in it to test; the demo exercises it on real hardware.
public struct SystemThermalProvider: ThermalStateProviding {
    public init() {}

    public var current: ThermalState {
        Self.map(ProcessInfo.processInfo.thermalState)
    }

    public func transitions() -> AsyncStream<ThermalState> {
        AsyncStream { continuation in
            // The observer token is an opaque NSObjectProtocol; the box makes
            // its single hand-off to onTermination visible to the compiler.
            final class TokenBox: @unchecked Sendable { var token: (any NSObjectProtocol)? }
            let box = TokenBox()
            box.token = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil, queue: nil
            ) { _ in
                continuation.yield(Self.map(ProcessInfo.processInfo.thermalState))
            }
            continuation.onTermination = { _ in
                if let token = box.token { NotificationCenter.default.removeObserver(token) }
            }
        }
    }

    static func map(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical   // unknown heat is treated as bad heat
        }
    }
}
