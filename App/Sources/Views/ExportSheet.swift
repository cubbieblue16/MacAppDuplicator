import AppKit
import SwiftUI

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exportedURL: URL

    private var command: String { "xattr -dr com.apple.quarantine \"\(exportedURL.path)\"" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Shortcut").font(.headline)
            Text("The exported shortcut is signed with your identity. On another Mac, Gatekeeper may block it until you remove the quarantine flag:")
                .fixedSize(horizontal: false, vertical: true)
            Text(command)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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
    }
}
