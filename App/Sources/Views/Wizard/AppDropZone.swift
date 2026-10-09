import SwiftUI

struct AppDropZone: View {
    let onDrop: (URL) -> Void
    let onBrowse: () -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app")
            Text("Drop an app here")
            Spacer()
            Button("Browse…", action: onBrowse)
        }
        .padding(12)
        .background(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6])).foregroundStyle(.secondary))
        .dropDestination(for: URL.self) { urls, _ in
            guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            onDrop(app)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
