// The `memory-fit` instrument: how much memory the local mind and the
// neural voice each cost, and what they cost together.
import Foundation
import MultiModalKitMLX
import MultiModalKitTTS

// MARK: - memory-fit: do the mind and the mouth fit together?

/// `swift run bakeoff memory-fit --model=<weights>`
///
/// From a phone crash: "Terminated due to memory issue" with the local
/// mind on 4B and the NEURAL voice selected. iOS jetsam does not
/// negotiate, so the question is arithmetic — how big is each, and do
/// they fit? This loads them one at a time and prints the footprint iOS
/// would actually judge (phys_footprint, not resident size).
@MainActor
func runMemoryFit(_ arguments: [String]) async {
    func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    print(String(format: "baseline            %8.0f MB", footprintMB()))

    // HELD for the whole measurement. The first version let this go out
    // of scope, the weights were freed, and the footprint went DOWN after
    // adding the voice — a measurement that flattered the answer.
    var heldMind: LocalMindModel?
    if let given = arguments.first(where: { $0.hasPrefix("--model=") }) {
        let path = String(given.dropFirst("--model=".count))
        let model = LocalMindModel(weights: URL(filePath: path))
        heldMind = model
        if MLXRuntime.isAvailable, (try? await model.ensureModel()) != nil {
            print(String(format: "+ local mind        %8.0f MB  (MLX active %d MB)",
                         footprintMB(), MLXRuntime.activeMemoryBytes / 1_048_576))
        } else {
            print("+ local mind        SKIPPED (no metallib or no weights)")
        }
    }

    let voice = NeuralVoice()
    if await voice.modelInstalled() {
        do {
            try await voice.ensureModel()
            print(String(format: "+ neural voice      %8.0f MB", footprintMB()))
        } catch {
            print("+ neural voice      FAILED: \(error)")
        }
    } else {
        print("+ neural voice      SKIPPED (not installed on this Mac)")
    }
    print(String(format: "BOTH TOGETHER       %8.0f MB", footprintMB()))
    _ = heldMind          // keep the weights alive to the very end
    print("")
    print("A Mac has no jetsam. iOS kills an app well below its RAM — the")
    print("budget is a few GB on a modern iPhone, and this total is what")
    print("counts against it.")
    exit(0)
}
