import DuplicatorCore
import SwiftUI

struct DeleteShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: ShortcutRecord
    let onDelete: (Bool) async -> Void
    @State private var removeData = false

    private var dataPath: String {
        record.config.dataPath ?? ShortcutConfig.defaultDataPath(forSlug: record.config.slug, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(record.name)”?").font(.headline)
            Text("The shortcut is moved to the Trash. The target app is never touched.")
            Toggle("Also move the data folder to the Trash", isOn: $removeData)
            Text(dataPath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    Task {
                        await onDelete(removeData)
                        dismiss()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
