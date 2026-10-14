import SwiftUI

/// The one-time review of shortcuts an earlier App Duplicator (or madctl) built before install tokens existed
/// (`LegacyTrustReview`). As in `ForeignShortcutApprovalSheet`, every value is shown in full, unmasked and verbatim, and
/// nothing is written until the user chooses Trust All and Rebuild. The same sheet then shows progress and results.
struct LegacyTrustReviewSheet: View {
    @Environment(AppState.self) private var appState
    let review: LegacyTrustReview
    @State private var isWorking = false
    @State private var results: [RebuildResult]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let results {
                Text(RebuildSummary.text(for: results)).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(results) { result in
                            RebuildResultRow(result: result)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                HStack {
                    Spacer()
                    Button("Done") { appState.closeLegacyTrustReview() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Label("Shortcuts from an earlier version", systemImage: "hand.raised").font(.headline)
                Text(verbatim: explanation)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(Array(review.approvals.enumerated()), id: \.element.id) { index, approval in
                            if index > 0 {
                                Divider().gridCellUnsizedAxes(.horizontal)
                            }
                            rows(for: approval)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                if isWorking, let progress = appState.rebuildProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text("\(progress.done) of \(progress.total) done")
                    }
                }
                HStack {
                    Spacer()
                    Button("Not now", role: .cancel) { appState.postponeLegacyTrustReview() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isWorking)
                    // Deliberately not the default action: Return must not approve without a look.
                    Button("Trust All and Rebuild") {
                        isWorking = true
                        Task {
                            results = await appState.trustLegacyShortcuts(review)
                            isWorking = false
                        }
                    }
                    .disabled(isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(isWorking)
    }

    private var explanation: String {
        let count = review.approvals.count
        let built = count == 1
            ? "This shortcut was built by an earlier App Duplicator (or madctl) before shortcuts were stamped as yours, so it reads"
            : "These \(count) shortcuts were built by an earlier App Duplicator (or madctl) before shortcuts were stamped as yours, so they read"
        let them = count == 1 ? "it" : "them"
        return "\(built) as not created here. Trust All and Rebuild signs \(them) as your own and trusts \(them) from then on. "
            + "Check every value first."
    }

    /// One block per shortcut: name, kind, target and signer always; the other rows only when they carry data.
    @ViewBuilder
    private func rows(for approval: ForeignShortcutApproval) -> some View {
        row("Name", [approval.config.name])
        row("Kind", [approval.kindDescription])
        row("Target", [approval.targetDescription])
        if !approval.argumentLines.isEmpty {
            row("Arguments", approval.argumentLines)
        }
        if !approval.environmentLines.isEmpty {
            row("Environment", approval.environmentLines)
        }
        if approval.config.dataPath != nil {
            row("Data path", [approval.dataPathDescription])
        }
        if approval.config.eraseOnQuit {
            row("Erase on quit", [approval.eraseOnQuitDescription])
        }
        row("Signer", [approval.signerDescription])
    }

    private func row(_ label: String, _ lines: [String]) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
