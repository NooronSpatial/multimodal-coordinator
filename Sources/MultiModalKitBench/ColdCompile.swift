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
/// D-075 widened the hunt: the ❄'s first surviving field report proved
/// the app's Caches holds NO compile cache on iOS, so the survey now
/// walks a LIST of directories — the app passes Caches AND tmp/. The
/// ruling carries its own ending: if tmp/ is empty too, cold is accepted
/// as system-owned (§30's number stands) with no new fork.
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
/// does not reach — that is a FINDING, and the next prefix (or the next
/// directory, as D-075 was) goes through a review, not a hotfix.
public struct CompiledPlanCache: Sendable {
    /// A directory this control found (or deleted): where it sat (the
    /// surveyed directory's last path component — "Caches" or "tmp" in
    /// the app), its name, and the bytes it held at survey time.
    public struct Entry: Sendable, Equatable {
        public let location: String
        public let name: String
        public let bytes: Int
    }

    public struct ClearReport: Sendable {
        public let deleted: [Entry]
        /// Found by the survey but NOT deleted — a removeItem that failed.
        /// Absent from the first version, so a failed delete simply
        /// vanished from the report and a half-warm cache read as cold.
        public let failed: [Entry]
        /// One human sentence for the screen and the log.
        public let summary: String
    }

    /// The cache-directory prefixes CoreML and the ANE compiler are known
    /// to use. Anything else in a surveyed directory is not ours to touch.
    public static let prefixes = ["com.apple.e5rt", "com.apple.CoreML",
                                  "com.apple.mlcompiler"]

    public let directories: [URL]

    /// The app passes its container's Caches and tmp (D-075); tests pass
    /// seeded temporary ones. There is no default on purpose — a wrong
    /// default here deletes someone's caches.
    public init(directories: [URL]) {
        self.directories = directories
    }

    /// What exists right now, across every directory, without touching it.
    public func survey() -> [Entry] {
        directories.flatMap(survey(in:))
    }

    private func survey(in directory: URL) -> [Entry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap { url in
            let name = url.lastPathComponent
            guard Self.prefixes.contains(where: name.hasPrefix) else { return nil }
            return Entry(location: directory.lastPathComponent,
                         name: name, bytes: directoryBytes(url))
        }
    }

    /// Deletes what the survey found, and reports exactly that.
    public func clear() -> ClearReport {
        let found = directories.map { ($0, survey(in: $0)) }
        guard found.contains(where: { !$1.isEmpty }) else {
            // Absence NAMES each neighbourhood. If the prefixes (or the
            // directory list) miss the real cache, the next field report
            // must carry the evidence to extend them — the names that ARE
            // there, per directory — instead of a shrug the reader cannot
            // act on. "tmp holds: [nothing]" is itself the line AC-172's
            // fall-through to C rests on.
            let where_ = directories.map(\.lastPathComponent).joined(separator: " or ")
            let hoods = directories.map(neighbourhood(of:)).joined(separator: " · ")
            return ClearReport(deleted: [], failed: [], summary:
                "no compiled-plan cache found under \(where_)"
                + " — the next load was already going to be cold, or the cache"
                + " lives somewhere this control does not reach. \(hoods)")
        }
        var deleted: [Entry] = []
        var failed: [Entry] = []
        for (directory, entries) in found {
            for entry in entries {
                let url = directory.appending(path: entry.name)
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    deleted.append(entry)
                } else {
                    failed.append(entry)
                }
            }
        }
        let total = deleted.reduce(0) { $0 + $1.bytes }
        let names = deleted.map { "\($0.location)/\($0.name)" }.joined(separator: ", ")
        var summary = "cleared \(deleted.count) compiled-plan cache(s), \(total) bytes: \(names)"
        if !failed.isEmpty {
            summary += " · COULD NOT DELETE "
                + failed.map { "\($0.location)/\($0.name)" }.joined(separator: ", ")
                + " — the next load may still be warm"
        }
        return ClearReport(deleted: deleted, failed: failed, summary: summary)
    }

    /// One directory's contents by name — or the honest admission that it
    /// could not be read. "holds: [nothing]" over a directory that was
    /// never opened would be the instrument fault again, one layer down.
    private func neighbourhood(of directory: URL) -> String {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else {
            return "\(directory.lastPathComponent) is unreadable or absent"
        }
        let present = contents.map(\.lastPathComponent).sorted().joined(separator: ", ")
        return "\(directory.lastPathComponent) holds: [\(present.isEmpty ? "nothing" : present)]"
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
