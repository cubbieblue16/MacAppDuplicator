import SwiftUI

struct InstalledAppsGrid: View {
    let apps: [InstalledApp]
    @Binding var selection: URL?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(apps) { app in
                    VStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 48, height: 48)
                        Text(app.name)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 96, height: 84)
                    .padding(6)
                    .background(selection == app.url ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = app.url }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selection == app.url ? .isSelected : [])
                    .accessibilityLabel(app.name)
                }
            }
            .padding(4)
        }
    }
}
