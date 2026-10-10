import DuplicatorCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: appState.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            SigningSettingsTab(settings: appState.settings)
                .tabItem { Label("Signing", systemImage: "checkmark.seal") }
            DataSettingsTab(settings: appState.settings)
                .tabItem { Label("Data", systemImage: "folder.badge.gearshape") }
        }
        .frame(width: 560, height: 400)
        .padding()
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            LabeledContent("Output folder") {
                HStack {
                    Text(settings.outputFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { chooseOutput() }
                    Button("Reset to Default") {
                        settings.outputFolder = AppSettings.defaultOutputFolder(home: FileManager.default.homeDirectoryForCurrentUser)
                    }
                }
            }
            LabeledContent("Library folders") {
                VStack(alignment: .leading, spacing: 6) {
                    List {
                        Label(settings.outputFolder.path, systemImage: "lock")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        ForEach(settings.libraryFolders, id: \.self) { folder in
                            HStack {
                                Text(folder.path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    settings.libraryFolders.removeAll { $0 == folder }
                                } label: { Image(systemName: "minus") }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(minHeight: 110)
                    Button { addLibraryFolder() } label: { Image(systemName: "plus") }
                }
            }
            Button("Open Logs Folder") { LogFolderOpener.open() }
            Text("Shortcuts are rescanned at launch, when this list changes, and when a bundle is added, removed or renamed in one of these folders. After editing a bundle in place, choose View → Refresh (⌘R).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.outputFolder
        if panel.runModal() == .OK, let url = panel.url { settings.outputFolder = url }
    }

    private func addLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url, url != settings.outputFolder, !settings.libraryFolders.contains(url) {
            settings.libraryFolders.append(url)
        }
    }
}

private struct SigningSettingsTab: View {
    @Bindable var settings: AppSettings
    @State private var identities: [String] = []

    private var isMissing: Bool {
        settings.signingIdentity != AppSettings.adHocIdentityName && !identities.contains(settings.signingIdentity)
    }

    var body: some View {
        Form {
            Picker("Signing identity", selection: $settings.signingIdentity) {
                Text(AppSettings.adHocIdentityName).tag(AppSettings.adHocIdentityName)
                ForEach(identities, id: \.self) { Text($0).tag($0) }
                if isMissing { Text(settings.signingIdentity).tag(settings.signingIdentity) }
            }
            Text("Developer ID lets Gatekeeper trust exported shortcuts on other Macs. Ad-hoc signatures only work on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if isMissing {
                Label("Identity not found in keychain; new shortcuts will be signed ad-hoc.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .task { identities = await Task.detached { SigningIdentities.load() }.value }
    }
}

private struct DataSettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOME override symlinks").font(.headline)
            Text("When a shortcut runs with a separate HOME, these entries are linked back to your real home folder so the app still sees them.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Changes apply to shortcuts created afterwards, when their separate HOME folder is first built. Existing shortcuts, and HOME folders already built, keep their links.")
                .font(.caption).foregroundStyle(.secondary)
            HomeSymlinkListEditor(entries: $settings.homeSymlinkEntries)
            HStack {
                Spacer()
                Button("Reset to Default") { settings.homeSymlinkEntries = HomeTreeBuilder.defaultSymlinkEntries }
            }
        }
        .padding(.top, 8)
    }
}
