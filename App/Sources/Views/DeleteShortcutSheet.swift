import DuplicatorCore
import SwiftUI

/// Confirms a delete. The data-folder toggle appears only for a folder `AppState.dataFolderDeletionOption` approved
/// (final review I1): never for Disabled mode, a missing folder, or a folder `DataPathGuard` refuses. Trashing a
/// folder outside the data root takes a second, destructive confirmation that names it (re-review Minor 1, final
/// review M24). A web app has no data folder; its second step asks whether to remove its web data too, and the
/// default button keeps it.
struct DeleteShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: ShortcutRecord
    let dataFolder: DataFolderDeletionOption
    let onDelete: (DeleteRequest) async -> Void
    @State private var removeData = false
    @State private var pendingConfirmation: DeleteConfirmation?

    private var isWebApp: Bool { record.config.kind == .webApp }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(record.name)”?").font(.headline)
            Text(isWebApp ? "The web app is moved to the Trash." : "The shortcut is moved to the Trash. The target app is never touched.")
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
                    if isWebApp {
                        pendingConfirmation = DeleteConfirmation.webData(shortcutName: record.name)
                        return
                    }
                    let removesData = removeData && isDataFolderAvailable
                    if let confirmation = DeleteConfirmation(shortcutName: record.name, option: dataFolder, removeData: removesData) {
                        pendingConfirmation = confirmation
                    } else {
                        delete(DeleteRequest(removeDataFolder: removesData, removeWebData: false))
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { _ in
            if isWebApp {
                Button("Keep Web Data") { delete(.keepAll) }.keyboardShortcut(.defaultAction)
                Button("Remove Web Data", role: .destructive) { delete(DeleteRequest(removeDataFolder: false, removeWebData: true)) }
            } else {
                Button("Move to Trash", role: .destructive) { delete(DeleteRequest(removeDataFolder: true, removeWebData: false)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var isDataFolderAvailable: Bool {
        if case .available = dataFolder { true } else { false }
    }

    private func delete(_ request: DeleteRequest) {
        Task {
            await onDelete(request)
            dismiss()
        }
    }
}
