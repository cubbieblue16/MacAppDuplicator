import SwiftUI

/// The review before a shortcut this App Duplicator did not create is rewritten and signed as the user's own (security
/// review C3). A received or planted bundle can carry any target, argument, environment variable or other setting, so every
/// field (`ForeignShortcutApproval.reviewRows`) is shown in full and unmasked. Values are rendered verbatim so nothing in them is read as Markdown.
struct ForeignShortcutApprovalSheet: View {
    @Environment(AppState.self) private var appState
    let approval: ForeignShortcutApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Not created here", systemImage: "hand.raised").font(.headline)
            Text(verbatim: "\u{201C}\(approval.config.name)\u{201D} was not created by this App Duplicator (\(approval.reason)). "
                + "Trust and Rebuild signs it as your own and trusts it from then on. Check every value first.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    // Every field of the config, defaults included; `ForeignShortcutApproval.reviewRows` is the one list.
                    ForEach(approval.reviewRows) { reviewRow in
                        row(reviewRow.label, reviewRow.lines)
                    }
                    row("Not created here", [approval.reason])
                    row("Signer", [approval.signerDescription])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Review in Editor", role: .cancel) { appState.cancelForeignApproval() }
                    .keyboardShortcut(.cancelAction)
                // Deliberately not the default action: Return must not approve without a look.
                Button("Trust and Rebuild") {
                    Task { await appState.approveForeignShortcut(approval) }
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func row(_ label: String, _ lines: [String]) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 2) {
                if lines.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
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
}
