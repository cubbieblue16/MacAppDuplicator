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
                Button { appState.isWizardPresented = true } label: { Label("New", systemImage: "plus") }
                    .help("New Shortcut (⌘N)")
            }
            ToolbarItem {
                Button("Rebuild All") { isRebuildAllPresented = true }
                    .disabled(appState.library.recordsNeedingRebuild.isEmpty)
            }
            ToolbarItem {
                Button("Check Profile Updates") { Task { await appState.checkProfileUpdates() } }
                    .disabled(appState.profiles.isChecking)
                    .help("Download the latest compatibility profiles from the profiles URL in Settings")
            }
        }
        .sheet(isPresented: $appState.isWizardPresented) {
            NewShortcutWizard()
        }
        .sheet(isPresented: $isRebuildAllPresented) {
            RebuildAllSheet(
                count: appState.library.recordsNeedingRebuild.filter { !$0.isForeign }.count,
                skippedCount: appState.library.recordsNeedingRebuild.filter(\.isForeign).count
            ) {
                await appState.rebuildAll()
            }
        }
        .sheet(item: $appState.pendingForeignApproval) { approval in
            ForeignShortcutApprovalSheet(approval: approval)
        }
        .alert(item: $appState.pendingError) { error in
            Alert(title: Text(error.context), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .alert("Check Profile Updates", isPresented: isProfileUpdateAlertPresented) {
            Button("OK") { appState.profileUpdateMessage = nil }
        } message: {
            Text(appState.profileUpdateMessage ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            // Final review M5: a dropped shortcut is refused before the wizard opens on it.
            guard !TargetGuard.isShortcutBundle(at: app) else {
                appState.pendingError = AppError(context: "Not an app", message: TargetGuard.refusalMessage(forAppAt: app))
                return false
            }
            appState.wizardPrefillTarget = app
            appState.isWizardPresented = true
            return true
        }
    }

    /// Shows the Check Profile Updates result until it is dismissed.
    private var isProfileUpdateAlertPresented: Binding<Bool> {
        Binding(get: { appState.profileUpdateMessage != nil }, set: { if !$0 { appState.profileUpdateMessage = nil } })
    }
}
