import AppKit
import SwiftUI

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exportedURL: URL
    /// The exported shortcut's saved environment; only its keys are shown, never its values.
    var environment: [String: String] = [:]
    /// The exported shortcut's saved arguments; the notice names the secret-looking ones, never their values.
    var arguments: [String] = []
    /// Where the item that was already at `exportedURL` went in the Trash, or nil when there was none.
    var trashedExisting: URL? = nil
    /// Read from the exported copy (final review M10), so the copy never claims an identity the bundle does not carry.
    @State private var signature: CodeSignature = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Shortcut").font(.headline)
            Text(ExportInstructions.signingSentence(for: signature))
                .fixedSize(horizontal: false, vertical: true)
            // C3: the recipient reviews and rebuilds the copy in App Duplicator instead of stripping its quarantine flag.
            Text(ExportInstructions.recipientSteps)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = ExportInstructions.secretNotice(for: environment, arguments: arguments) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let trashedExisting {
                Label {
                    Text(verbatim: "The item that was at \(exportedURL.path) is in the Trash: \(trashedExisting.path)")
                } icon: {
                    Image(systemName: "trash")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
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
