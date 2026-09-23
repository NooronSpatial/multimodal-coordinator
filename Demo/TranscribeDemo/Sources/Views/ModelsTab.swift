import MultiModalKit
import SwiftUI

/// THE MODELS TAB (5a, AC-300) — the screen a person downloads and
/// deletes from, and the proof a reader can run on hardware.
///
/// Every row is `any ModelBacked`. The screen shows a percentage while
/// bytes move, a size before the tap, and a Delete — three things this
/// app could not show before 5a, and it shows them the same way for the
/// ear, the mind and both mouths without knowing which is which.
///
/// WHAT TO DO ON THE PHONE, which is what this screen exists to make
/// possible (Ryad's gate):
///
///   1. Tap Download on the mind. Lock the phone for five minutes.
///      Unlock: the percentage has MOVED.
///   2. Tap Download. Kill the app from the switcher mid-transfer.
///      Relaunch, open this tab, tap Download again: it continues from
///      where it stopped — the server is asked for a range, not the
///      whole file.
///   3. Tap Delete. The row reads "not installed", and the other
///      engines' rows are untouched.
///
/// No "keep the app open" sentence anywhere on this screen, and that
/// absence is the milestone: it was the first line of the diet app's
/// requirement, and it is gone because the transfer no longer needs it.
struct ModelsTab: View {
    let models: ModelsState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(models.rows) { row in
                        ModelRowView(row: row)
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("Downloads continue while the app is in the background, "
                         + "and resume where they stopped. Deleting removes only that model's "
                         + "own files.")
                }
            }
            .navigationTitle("Models")
            .task { await models.refreshAll() }
            .refreshable { await models.refreshAll() }
        }
    }
}

/// One engine's row: what it is, how big, what it is doing, and the two
/// buttons.
struct ModelRowView: View {
    let row: ModelRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.headline)
                    Text(row.role).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.size).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }

            switch row.state {
            case .downloading(let fraction):
                // THE PERCENTAGE THE REQUIREMENT ASKED FOR, and it is
                // BYTES on four of the five engines — not a count of
                // files finished, which is what the vendors' clients
                // report and what made a 2.2 GB bar jump from 11 % to
                // 100 %.
                ProgressView(value: fraction) {
                    Text("Downloading").font(.caption)
                } currentValueLabel: {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                }
            case .deleting:
                ProgressView().controlSize(.small)
            default:
                EmptyView()
            }

            HStack {
                Label(stateWords, systemImage: stateSymbol)
                    .font(.caption)
                    .foregroundStyle(row.state == .installed ? .green : .secondary)
                Spacer()
                Button("Download") { Task { await row.download() } }
                    .buttonStyle(.bordered)
                    .disabled(row.state == .installed || isBusy)
                Button("Delete", role: .destructive) { Task { await row.delete() } }
                    .buttonStyle(.bordered)
                    .disabled(row.state != .installed)
            }

            if let note = row.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var isBusy: Bool {
        switch row.state {
        case .downloading, .deleting: true
        default: false
        }
    }

    private var stateWords: String {
        switch row.state {
        case .unknown: "checking…"
        case .installed: "installed"
        case .missing: "not installed"
        case .downloading: "downloading"
        case .deleting: "deleting"
        case .failed(let words): words
        }
    }

    private var stateSymbol: String {
        switch row.state {
        case .installed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        default: "circle.dashed"
        }
    }
}
