import Foundation

/// The cold-compile control's honest half (4n, AC-169, D-074 = B).
///
/// CoreML keeps its compiled execution plans in per-app cache
/// directories; while one exists, every load is WARM — under three
/// seconds and ~112 MB of transient on the phone that matters. The two
/// recorded kills and the vendor's 1.7B restriction are both about the
/// COLD compile, and before this type the only road to cold was deleting
/// the app and re-downloading ~3.3 GB.
///
/// ## The rule this type exists to keep
///
/// §30's fault, named again so it is not rebuilt: an instrument that
/// cannot see the thing it reports is worse than none. So this type
/// never claims — it SURVEYS what actually exists (names and bytes),
/// deletes only what it surveyed, and says absence in words. A "cleared"
/// over an empty directory is not a smaller success; it is a lie with
/// good manners.
///
/// The prefix list is deliberately visible: the field report is how we
/// learn which of these the device really uses. If a phone's report says
/// "no compiled-plan cache found", the cache lives somewhere this list
/// does not reach — that is a FINDING, and the next prefix goes through
/// a review, not a hotfix.
public struct CompiledPlanCache: Sendable {
    /// A directory this control found (or deleted): its name and the
    /// bytes it held at survey time.
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let bytes: Int
    }

    public struct ClearReport: Sendable {
        public let deleted: [Entry]
        /// One human sentence for the screen and the log.
        public let summary: String
    }

    /// The cache-directory prefixes CoreML and the ANE compiler are known
    /// to use. Anything else in Caches is not ours to touch.
    public static let prefixes = ["com.apple.e5rt", "com.apple.CoreML",
                                  "com.apple.mlcompiler"]

    public let cachesDirectory: URL

    /// The app passes its container's Caches directory; tests pass a
    /// seeded temporary one. There is no default on purpose — a wrong
    /// default here deletes someone's caches.
    public init(cachesDirectory: URL) {
        self.cachesDirectory = cachesDirectory
    }

    /// What exists right now, without touching it.
    public func survey() -> [Entry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: cachesDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap { url in
            let name = url.lastPathComponent
            guard Self.prefixes.contains(where: name.hasPrefix) else { return nil }
            return Entry(name: name, bytes: directoryBytes(url))
        }
    }

    /// Deletes what `survey()` found, and reports exactly that.
    public func clear() -> ClearReport {
        let found = survey()
        guard !found.isEmpty else {
            // Absence NAMES the neighbourhood. If the prefixes miss the
            // real cache, the next field report must carry the evidence
            // to extend them — the directory names that ARE there —
            // instead of a shrug the reader cannot act on.
            let present = ((try? FileManager.default.contentsOfDirectory(
                at: cachesDirectory, includingPropertiesForKeys: nil)) ?? [])
                .map(\.lastPathComponent).sorted().joined(separator: ", ")
            return ClearReport(deleted: [], summary:
                "no compiled-plan cache found under \(cachesDirectory.lastPathComponent)"
                + " — the next load was already going to be cold, or the cache"
                + " lives somewhere this control does not reach."
                + " Caches holds: [\(present.isEmpty ? "nothing" : present)]")
        }
        var deleted: [Entry] = []
        for entry in found {
            let url = cachesDirectory.appending(path: entry.name)
            if (try? FileManager.default.removeItem(at: url)) != nil {
                deleted.append(entry)
            }
        }
        let total = deleted.reduce(0) { $0 + $1.bytes }
        let names = deleted.map(\.name).joined(separator: ", ")
        return ClearReport(deleted: deleted, summary:
            "cleared \(deleted.count) compiled-plan cache(s), \(total) bytes: \(names)")
    }

    private func directoryBytes(_ url: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in walker {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}

/// AC-170's rule as one pure sentence, testable without a probe: a phase
/// that produced zero sampler lines watched a load that never happened.
/// The first field run printed `survived: yes` around exactly that, and
/// the null run went unnoticed until a human compared four identical
/// numbers by eye.
public enum PressurePhaseVerdict {
    /// `nil` when the phase really measured; the announcement otherwise.
    public static func nullRunLine(samples: Int, label: String) -> String? {
        guard samples == 0 else { return nil }
        return "  ⚠ the \(label) was ALREADY resident — zero sampler lines,"
            + " this phase measured nothing"
    }
}
