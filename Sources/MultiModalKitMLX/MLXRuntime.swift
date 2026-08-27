// `MLXRuntime` — the runtime guard: whether MLX may be called on this
// machine at all, and what its allocator is holding.

import Foundation
import MLX

// MARK: - the runtime guard (AC-129)

/// Whether MLX can be touched AT ALL on this machine, asked BEFORE
/// touching it.
///
/// This exists because of a measured failure mode, not a hypothetical
/// one (D-061, INSTRUMENTS §24): with no `default.metallib` reachable,
/// MLX does not throw and does not fail an assertion — it **aborts the
/// process**. A crashing test runner cannot report which test killed it,
/// so the only safe order is to look for the artefact with Foundation
/// first and never call into MLX if it is missing.
///
/// The check is deliberately CONSERVATIVE. A false negative means we
/// refuse to run when we could have; a false positive means the process
/// dies. Those costs are not symmetric, so the doubt goes one way.
public enum MLXRuntime {

    /// mlx-swift's own SwiftPM bundle name, from its `Package.swift`:
    /// `.define("SWIFTPM_BUNDLE", to: "\"mlx-swift_Cmlx\"")`.
    private static let cmlxBundleName = "mlx-swift_Cmlx"

    /// `<base>/mlx-swift_Cmlx.bundle/<resources>/default.metallib`, which
    /// is the shape `try_load_bundle` builds in device.cpp.
    private static func nestedCmlxLibrary(in base: URL) -> URL? {
        let nested = base.appending(path: "\(cmlxBundleName).bundle")
        guard let bundle = Bundle(url: nested),
              let resources = bundle.resourceURL else { return nil }
        let library = resources.appending(path: "default.metallib")
        return FileManager.default.fileExists(atPath: library.path) ? library : nil
    }

    /// Where the vendor's loader looks — MIRRORED from its source, and
    /// corrected TWICE by the AC-129 control rather than by reasoning.
    ///
    /// Both corrections are worth keeping, because both were false
    /// POSITIVES, and a false positive here is a dead process:
    ///
    /// 1. The first version searched each bundle for a nested Cmlx bundle
    ///    with `url(forResource:)`, which found one MLX never loads.
    /// 2. The second version accepted ANY bundle's
    ///    `Resources/default.metallib` — and matched
    ///    **`Vision.framework/Resources/default.metallib`**, because
    ///    Apple ships its own. MLX only accepts a framework whose bundle
    ///    IDENTIFIER is mlx-swift's own, which is exactly the check that
    ///    rules Vision out.
    ///
    /// The colocated `mlx.metallib` arrangements (steps 1, 2 and 4 of
    /// `load_default_library`) are deliberately NOT checked: they exist
    /// for non-SwiftPM builds this package does not produce, and every
    /// extra place to look is another chance to say yes wrongly. The cost
    /// is a false NEGATIVE for such a build — we would skip where MLX
    /// could have run — and that is the direction this check is allowed
    /// to be wrong in.
    public static func metallibURL() -> URL? {
        let files = FileManager.default
        // The app case: an .app carrying mlx-swift_Cmlx.bundle.
        if let found = nestedCmlxLibrary(in: Bundle.main.bundleURL) { return found }
        for bundle in Bundle.allBundles {
            if let resources = bundle.resourceURL,
               let found = nestedCmlxLibrary(in: resources) { return found }
        }
        // A dynamic framework wrapping it — the IDENTIFIER must match.
        for framework in Bundle.allFrameworks
        where framework.bundleIdentifier == cmlxBundleName {
            if let resources = framework.resourceURL {
                let library = resources.appending(path: "default.metallib")
                if files.fileExists(atPath: library.path) { return library }
            }
        }
        // The `swift test` case — INSTRUMENTS §24 STAGE 1's finding.
        let cwd = URL(filePath: files.currentDirectoryPath)
            .appending(path: "default.metallib")
        return files.fileExists(atPath: cwd.path) ? cwd : nil
    }

    /// What MLX is holding, in bytes — the number that decides whether a
    /// model fits on a PHONE.
    ///
    /// It matters because MLX does not memory-map its weights: there is
    /// no `mmap` anywhere in its C++ core (measured, INSTRUMENTS §25), so
    /// everything loaded is RESIDENT, beside the audio graph, the
    /// recogniser and the mouth. On a Mac that is invisible. On a phone
    /// it is the difference between a working app and one jetsam kills.
    ///
    /// Reading these NEVER touches the GPU, but it does construct MLX's
    /// allocator — so `isAvailable` is checked first, or the process
    /// would abort on a machine with no metallib.
    public static var activeMemoryBytes: Int { isAvailable ? MLX.Memory.activeMemory : 0 }
    public static var peakMemoryBytes: Int { isAvailable ? MLX.Memory.peakMemory : 0 }

    /// True when MLX may be called. `false` means SKIP — never "try and
    /// see", because trying is what aborts the process.
    ///
    /// The simulator is refused OUTRIGHT, before the artefact is even
    /// looked for, and this is not caution — it is D-061, measured:
    /// MLX asks Metal for a heap with `ResourceStorageModeShared` because
    /// it assumes the unified memory of real Apple silicon, and
    /// `MTLSimDevice` requires `Private` and refuses. `Device.cpu` does
    /// not escape it, because the allocator is chosen at BUILD time. The
    /// metallib IS present in a simulator app bundle, so a check that
    /// only looked for the file would say yes and then die on the first
    /// allocation — which is exactly what the phone spike did, twice.
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return metallibURL() != nil
        #endif
    }
}
