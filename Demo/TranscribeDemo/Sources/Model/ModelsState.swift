import Foundation
import MultiModalKit
import Observation

// THE MODELS SCREEN'S STATE (5a, AC-300) — one row per engine, and every
// row asks the same five questions of `any ModelBacked`.
//
// That existential is the point of the screen. Before 5a this app had
// three different download buttons in three places, each written against
// a different engine's own methods, and two of the five engines had no
// delete at all because the folder layout was the library's. Now the
// screen holds a list of protocol values and does not know — or need to
// know — which engine each one is.
//
//   modelInstalled()          is it here?
//   expectedDownloadBytes()   how big, before the tap, with no network
//   ensureModel(progress:)    fetch it, with a percentage
//   deleteModel()             remove exactly what that fetch wrote
//
// The transfer runs on the library's background session, so this screen
// may be left, the app may be suspended, and the bytes keep coming; the
// app delegate's one line (`TranscribeDemoApp`) is what lets the system
// wake the app when they land.

/// One engine's row.
@MainActor
@Observable
final class ModelRow: Identifiable {
    enum State: Equatable {
        case unknown
        case installed
        case missing
        /// 0…1 while the bytes move.
        case downloading(Double)
        case deleting
        case failed(String)
    }

    let id = UUID()
    /// What a person calls this engine.
    let name: String
    /// What it is for, in three words.
    let role: String
    let engine: any ModelBacked
    var state: State = .unknown
    /// The last thing that happened, in a sentence — sticky, so a
    /// failure before the first byte cannot look like an ignored tap
    /// (the field report `MindAssetsState` carries).
    var note: String?

    init(name: String, role: String, engine: any ModelBacked) {
        self.name = name
        self.role = role
        self.engine = engine
    }

    /// The size before the tap, in megabytes — or nothing, when the
    /// library honestly does not know (the mind before its first
    /// listing; the Apple engine always, because the system owns those
    /// bytes).
    var size: String {
        guard let bytes = engine.expectedDownloadBytes() else { return "—" }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }

    /// Asking is free: no network, no download.
    func refresh() async {
        state = await engine.modelInstalled() ? .installed : .missing
    }

    func download() async {
        guard case .downloading = state else {
            state = .downloading(0)
            note = "starting…"
            do {
                try await engine.ensureModel { fraction in
                    Task { @MainActor in
                        if case .deleting = self.state { return }
                        self.state = .downloading(fraction)
                    }
                }
                // Trust the DISK, not the call returning — Phase 2's
                // lesson, and the one a wrong model path taught twice.
                await refresh()
                note = state == .installed ? "installed." : "finished, but the files are not usable."
            } catch is CancellationError {
                await refresh()
                note = "stopped — what arrived is kept, and tapping again resumes."
            } catch {
                await refresh()
                note = "failed: \(error)"
            }
            return
        }
        note = "already downloading — ignoring the tap."
    }

    func delete() async {
        state = .deleting
        do {
            try await engine.deleteModel()
            await refresh()
            note = "deleted."
        } catch {
            await refresh()
            note = "could not delete: \(error)"
        }
    }
}

/// Every engine this app can install, as `any ModelBacked`.
@MainActor
@Observable
final class ModelsState {
    private(set) var rows: [ModelRow] = []

    /// Built from the app's own engines, so the rows are the objects the
    /// pipeline really uses — not copies that would report on a
    /// different install.
    func adopt(_ rows: [ModelRow]) {
        self.rows = rows
    }

    func refreshAll() async {
        for row in rows { await row.refresh() }
    }
}
