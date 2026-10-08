import Foundation

/// Which phone, which OS — the line every shared measurement carries, so a
/// number is never read without its device (PROBE-R's lesson, 5b; the turn
/// timeline's, 5d).
enum DeviceLine {
    static var current: String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? "unknown"
        }
        return "\(machine) · \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
