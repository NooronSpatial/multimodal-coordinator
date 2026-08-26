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
/// good manners. The same rule one layer down, both added by the D-075
/// review: a directory this control cannot READ is named "unreadable or
/// absent" in EVERY report, and a clear in which every delete failed
/// never opens with the word "cleared".
///
/// The prefix list is deliberately visible: the field report is how we
/// learn which of these the device really uses. If a phone's report says
/// "no compiled-plan cache found", the cache lives somewhere this list
/// does not reach — that is a FINDING, and the next prefix (or the next
/// directory, as D-075 was) goes through a review, not a hotfix.
///
/// ## Named limits (found by the D-075 review, kept on the record)
///
/// - A SYMLINK whose name matches a prefix is not touched: deleting the
///   link would leave the target's data answering warm while the report
///   claimed cold — the §30 lie with extra steps. It still shows in the
///   neighbourhood line. No OS is known to symlink these caches; if a
///   field report ever shows one, that is a finding.
/// - Byte counts are best-effort: a directory walk the OS interrupts
///   midway undercounts silently. The DELETION is exact; the number is
///   evidence, not accounting.
/// - `Entry.location` is the surveyed directory's last path component;
///   two surveyed roots sharing a last component would be
///   indistinguishable in the report. The app passes Caches and tmp.
/// - `survey()` alone cannot express "unreadable" — it returns entries
///   only. `clear()`'s summary is the honest reporter.
public struct CompiledPlanCache: Sendable {
    /// A cache this control found (or deleted): where it sat (the
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
    /// default here deletes someone's caches. Duplicates are dropped up
    /// front: the same directory listed twice once produced a report that
    /// called one deletion both done and failed.
    public init(directories: [URL]) {
        var seen = Set<URL>()
        self.directories = directories.filter {
            seen.insert($0.standardizedFileURL).inserted
        }
    }

    /// One directory, read ONCE. Entries and the neighbourhood line come
    /// from the same read, so the headline and the evidence line cannot
    /// disagree about a cache that appeared between two listings.
    private struct Scan {
        let directory: URL
        let entries: [Entry]
        /// nil when the directory could not be read at all.
        let names: [String]?
    }

    /// What exists right now, across every directory, without touching it.
    public func survey() -> [Entry] {
        directories.flatMap { scan($0).entries }
    }

    private func scan(_ directory: URL) -> Scan {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else {
            return Scan(directory: directory, entries: [], names: nil)
        }
        let entries = contents.compactMap { url -> Entry? in
            let name = url.lastPathComponent
            guard Self.prefixes.contains(where: name.hasPrefix) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // isSymbolicLink first: the other keys describe the TARGET.
            guard values?.isSymbolicLink != true else { return nil }
            let bytes = values?.isDirectory == true
                ? directoryBytes(url) : (values?.fileSize ?? 0)
            return Entry(location: directory.lastPathComponent,
                         name: name, bytes: bytes)
        }
        return Scan(directory: directory, entries: entries,
                    names: contents.map(\.lastPathComponent).sorted())
    }

    /// Deletes what the survey found, and reports exactly that.
    public func clear() -> ClearReport {
        let scans = directories.map(scan(_:))
        // A directory the control could not read is named in EVERY
        // report. The first version said so only when nothing matched
        // anywhere, so one found cache silenced the admission that a
        // whole directory went unsurveyed.
        let unreadable = scans.filter { $0.names == nil }.map {
            "\($0.directory.lastPathComponent) is unreadable or absent — not surveyed"
        }
        guard scans.contains(where: { !$0.entries.isEmpty }) else {
            // Absence NAMES each neighbourhood, from the same read the
            // verdict came from. "tmp holds: [nothing]" is itself the
            // line AC-172's fall-through to C rests on.
            let where_ = directories.map(\.lastPathComponent).joined(separator: " or ")
            let hoods = scans.map { scan -> String in
                guard let names = scan.names else {
                    return "\(scan.directory.lastPathComponent) is unreadable or absent"
                }
                let list = names.isEmpty ? "nothing" : names.joined(separator: ", ")
                return "\(scan.directory.lastPathComponent) holds: [\(list)]"
            }.joined(separator: " · ")
            return ClearReport(deleted: [], failed: [], summary:
                "no compiled-plan cache found under \(where_)"
                + " — the next load was already going to be cold, or the cache"
                + " lives somewhere this control does not reach. \(hoods)")
        }
        var deleted: [Entry] = []
        var failed: [Entry] = []
        for scan in scans {
            for entry in scan.entries {
                let url = scan.directory.appending(path: entry.name)
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    deleted.append(entry)
                } else {
                    failed.append(entry)
                }
            }
        }
        var summary: String
        if deleted.isEmpty {
            // Every delete failed. "cleared 0 ... 0 bytes:" would be a
            // malformed sentence wearing a success verb.
            summary = "could not delete any of \(failed.count) compiled-plan cache(s): "
                + failed.map { "\($0.location)/\($0.name)" }.joined(separator: ", ")
                + " — the next load may still be warm"
        } else {
            let total = deleted.reduce(0) { $0 + $1.bytes }
            let names = deleted.map { "\($0.location)/\($0.name)" }.joined(separator: ", ")
            summary = "cleared \(deleted.count) compiled-plan cache(s), \(total) bytes: \(names)"
            if !failed.isEmpty {
                summary += " · COULD NOT DELETE "
                    + failed.map { "\($0.location)/\($0.name)" }.joined(separator: ", ")
                    + " — the next load may still be warm"
            }
        }
        if !unreadable.isEmpty {
            summary += " · " + unreadable.joined(separator: " · ")
        }
        return ClearReport(deleted: deleted, failed: failed, summary: summary)
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
