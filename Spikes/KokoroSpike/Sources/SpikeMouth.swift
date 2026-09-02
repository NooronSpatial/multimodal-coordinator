import Foundation
#if os(iOS)
import Darwin
#endif

/// What the spike needs from a mouth, and nothing else.
///
/// **The timing does NOT live here.** It lives once, in `SpikeModel`, and
/// runs the same code around both mouths. A stopwatch that each vendor
/// starts for itself is a comparison with a thumb on the scale — and the
/// whole reason this app now holds two mouths is that the numbers we had
/// were measured under different conditions.
protocol SpikeMouth: Actor {
    nonisolated var name: String { get }
    /// Fetches and loads whatever it needs. Kokoro's weights come from
    /// the app's own downloader; TTSKit fetches its own.
    func load() async throws
    /// One decode, all of it.
    ///
    /// The rate travels WITH the samples rather than being asked for
    /// separately, so a decoder and a format cannot disagree — that
    /// disagreement is the fault the field reported as a voice "speaking
    /// in weird way like someone drunk", 24 kHz played as 16 kHz. Here it
    /// is unrepresentable.
    func speak(_ text: String) async throws -> (samples: [Float], sampleRate: Int)
    /// A vendor's own peak counter, when it keeps one. MLX does; CoreML
    /// does not — which is exactly why the footprint sampler exists.
    nonisolated var vendorPeakBytes: Int? { get }
}

extension SpikeMouth {
    nonisolated var vendorPeakBytes: Int? { nil }
}

/// This process's real memory footprint — the number Xcode's gauge shows.
///
/// `phys_footprint`, not resident size: it is what iOS actually judges an
/// app on, and the field crash was that judgment.
enum ProcessMemory {
    static var footprintBytes: Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size)
            / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint)
    }
}

/// The highest footprint seen while something ran.
///
/// A vendor peak counter cannot be the shared metric — MLX keeps one and
/// CoreML does not — so the only number that describes BOTH mouths on the
/// same terms is the process's own footprint, watched while it works.
///
/// This samples, and sampling is a compromise this project usually
/// refuses. It is allowed here for the reason the pressure probe already
/// uses it: the quantity is continuous and there is no event to gate on.
/// The cost is stated rather than hidden — **a spike shorter than the
/// interval is invisible**, so a reported peak is a floor, never a
/// ceiling.
actor FootprintSampler {
    static let intervalMilliseconds = 20

    private var peak = 0
    private var task: Task<Void, Never>?

    func start() {
        peak = ProcessMemory.footprintBytes ?? 0
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: .milliseconds(Self.intervalMilliseconds))
            }
        }
    }

    private func sample() {
        guard let now = ProcessMemory.footprintBytes else { return }
        peak = max(peak, now)
    }

    /// Stops the sampler and reports the highest it saw. One last sample
    /// is taken first, so a decode that ends between two ticks still
    /// contributes its final reading.
    func stop() -> Int {
        task?.cancel()
        task = nil
        sample()
        return peak
    }
}
