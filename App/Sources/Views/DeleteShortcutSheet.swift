import DuplicatorCore
import SwiftUI

/// Confirms a delete. The data-folder toggle appears only for a folder `AppState.dataFolderDeletionOption` approved
/// (final review I1): never for Disabled mode, a missing folder, or a folder `DataPathGuard` refuses.
struct DeleteShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: ShortcutRecord
    let dataFolder: DataFolderDeletionOption
    let onDelete: (Bool) async -> Void
    @State private var removeData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(record.name)”?").font(.headline)
            Text("The shortcut is moved to the Trash. The target app is never touched.")
            switch dataFolder {
            case .unavailable(let note):
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .available(let folder, let outsideDataRoot):
                Toggle("Also move the data folder to the Trash", isOn: $removeData)
                Text(folder.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if outsideDataRoot {
                    Label("This folder is outside ~/Library/Application Support/App Duplicator: \(folder.path)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    Task {
                        await onDelete(removeData && isDataFolderAvailable)
                        dismiss()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var isDataFolderAvailable: Bool {
        if case .available = dataFolder { true } else { false }
    }
}
