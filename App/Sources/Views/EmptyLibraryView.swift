import SwiftUI

struct EmptyLibraryView: View {
    let onNew: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No shortcuts yet", systemImage: "square.on.square.dashed")
        } description: {
            Text("Create a shortcut to run a second copy of an app with its own data, icon and Dock tile.")
        } actions: {
            Button("New Shortcut…", action: onNew).buttonStyle(.borderedProminent)
        }
    }
}
