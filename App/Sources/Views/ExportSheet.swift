import AppKit
import SwiftUI

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exportedURL: URL
    /// The exported shortcut's saved environment; only its keys are shown, never its values.
    var environment: [String: String] = [:]
    /// The exported shortcut's saved arguments; the notice names the secret-looking ones, never their values.
    var arguments: [String] = []
    /// Read from the exported copy (final review M10), so the copy never claims an identity the bundle does not carry.
    @State private var signature: CodeSignature = .unknown

    private var command: String { ExportInstructions.quarantineCommand(for: exportedURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Shortcut").font(.headline)
            Text(ExportInstructions.signingSentence(for: signature))
                .fixedSize(horizontal: false, vertical: true)
            Text(command)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            if let notice = ExportInstructions.secretNotice(for: environment, arguments: arguments) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            let url = exportedURL
            signature = await Task.detached { CodeSignature.of(bundleAt: url) }.value
        }
    }
}
