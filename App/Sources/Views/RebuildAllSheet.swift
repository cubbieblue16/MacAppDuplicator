import SwiftUI

/// Rebuild All (spec §7 toolbar): asks first, rebuilds every stale shortcut with progress, then lists each result
/// (final review M16). The sheet stays open after the rebuild so failures can be read.
struct RebuildAllSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let onRebuild: () async -> [RebuildResult]
    @State private var isWorking = false
    @State private var results: [RebuildResult]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let results {
                Text(RebuildSummary.text(for: results)).font(.headline)
                if results.contains(where: { $0.outcome != .rebuilt }) {
                    Text("Shortcuts that failed keep their Needs rebuild badge. Fix the cause, then run Rebuild All again.")
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(results) { result in
                            RebuildResultRow(result: result)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(count == 1 ? "Rebuild 1 shortcut?" : "Rebuild \(count) shortcuts?").font(.headline)
                Text("Each shortcut is rewritten with the current launcher and signed again. Settings are kept.")
                if let progress = appState.rebuildProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text("\(progress.done) of \(progress.total) done")
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                    Button("Rebuild") {
                        isWorking = true
                        Task {
                            results = await onRebuild()
                            isWorking = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(isWorking)
    }
}

/// One shortcut's line in the results: a check mark, or a warning with the error underneath.
private struct RebuildResultRow: View {
    let result: RebuildResult

    var body: some View {
        switch result.outcome {
        case .rebuilt:
            Label(result.name, systemImage: "checkmark.circle")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Label(result.name, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
