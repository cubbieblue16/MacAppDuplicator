import SwiftUI

struct NewShortcutWizard: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("The New Shortcut wizard arrives in Task 7.")
            Button("Close") { dismiss() }
        }
        .padding(24)
    }
}
