import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var isRebuildAllPresented = false

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            SidebarView(selection: $appState.selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let record = appState.selectedRecord {
                ShortcutEditorView(record: record)
                    .id(record.bundleURL)
            } else if appState.library.records.isEmpty {
                EmptyLibraryView { appState.isWizardPresented = true }
            } else {
                ContentUnavailableView("Select a shortcut", systemImage: "square.on.square")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { appState.isWizardPresented = true } label: { Label("New Shortcut", systemImage: "plus") }
                    .help("New Shortcut (⌘N)")
            }
            ToolbarItem {
                Button("Rebuild All") { isRebuildAllPresented = true }
                    .disabled(appState.library.recordsNeedingRebuild.isEmpty)
            }
        }
        .sheet(isPresented: $appState.isWizardPresented) {
            NewShortcutWizard()
        }
        .sheet(isPresented: $isRebuildAllPresented) {
            RebuildAllSheet(count: appState.library.recordsNeedingRebuild.count) {
                _ = await appState.rebuildAll()
            }
        }
        .alert(item: $appState.pendingError) { error in
            Alert(title: Text(error.context), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            appState.wizardPrefillTarget = app
            appState.isWizardPresented = true
            return true
        }
    }
}
