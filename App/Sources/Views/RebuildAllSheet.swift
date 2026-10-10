import SwiftUI

struct RebuildAllSheet: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let onRebuild: () async -> Void
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(count == 1 ? "Rebuild 1 shortcut?" : "Rebuild \(count) shortcuts?").font(.headline)
            Text("Each shortcut is rewritten with the current launcher and signed again. Settings are kept.")
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                Button("Rebuild") {
                    isWorking = true
                    Task {
                        await onRebuild()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
