import CompatProfiles
import DuplicatorCore
import SwiftUI

/// Edits a copy of the record's config; Save rewrites and signs the bundle, Revert discards (spec §7).
struct ShortcutEditorView: View {
    @Environment(AppState.self) private var appState
    let record: ShortcutRecord

    @State private var draft: ShortcutConfig
    @State private var inspected: InspectedApp?
    @State private var isSaving = false
    @State private var isDuplicatePromptPresented = false
    @State private var duplicateName = ""
    @State private var exportOutcome: ShortcutBuilder.ExportOutcome?
    /// An export destination inside a library folder, waiting for Export Anyway (re-review Minor 5).
    @State private var pendingLibraryExport: URL?
    @State private var isDeletePresented = false
    @State private var isDiagnosticsPresented = false
    /// False while the web address field holds something that is not an https address (Save is disabled then).
    @State private var webURLIsValid = true
    /// Bumped by Revert so the web section rebuilds its local text fields from the restored draft.
    @State private var revertCount = 0

    init(record: ShortcutRecord) {
        self.record = record
        _draft = State(initialValue: record.config)
    }

    private var hasChanges: Bool { draft != record.config }

    private var isWebApp: Bool { record.config.kind == .webApp }

    private var isLauncher: Bool { LauncherEditorPolicy.isLauncherKind(record.config.kind) }

    /// The profile for the draft's target, read from the profiles in use (never copied into the draft here).
    private var profile: AppProfile? { appState.profile(forBundleIdentifier: draft.targetBundleIdentifier) }

    var body: some View {
        Form {
            IdentitySection(draft: $draft, record: record, inspected: inspected)
            if isWebApp {
                // A web app has no target, profile, launch mode or data folder; its options live in one section.
                WebAppSection(draft: $draft, record: record, urlIsValid: $webURLIsValid).id(revertCount)
            } else if isLauncher {
                // A launcher has no target app, profile, launch mode or data mode; its settings live in one section.
                if record.config.kind == .cli {
                    CommandSection(draft: $draft).id(revertCount)
                } else {
                    FileSection(draft: $draft)
                }
            } else {
                TargetSection(draft: $draft, inspected: inspected, profile: profile)
                ProfileSection(bundleIdentifier: draft.targetBundleIdentifier, profile: profile, detectedFamily: inspected?.family)
                LaunchSection(draft: $draft, record: record, inspected: inspected)
                AdvancedSection(draft: $draft)
            }
            Section("Actions") {
                HStack {
                    Button("Launch") { Task { await appState.launch(record) } }
                        .disabled(!record.targetExists)
                    Button("Reveal in Finder") { appState.reveal(record) }
                    Button("Regenerate") { Task { await appState.regenerate(record) } }
                    Button("Duplicate") {
                        duplicateName = "\(record.name) Copy"
                        isDuplicatePromptPresented = true
                    }
                    Button("Export…") { exportPanel() }
                    Button("Diagnostics…") { isDiagnosticsPresented = true }
                    Button("Delete", role: .destructive) { isDeletePresented = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(record.name)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if record.needsRebuild {
                    Label(
                        "Built by an older engine version (\(record.engineVersion), current \(ShortcutConfig.currentEngineVersion)). Regenerate to update.",
                        systemImage: "exclamationmark.triangle"
                    )
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") {
                    draft = record.config
                    webURLIsValid = true
                    revertCount += 1
                }
                .disabled(!(hasChanges || !webURLIsValid) || isSaving)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        !hasChanges || isSaving || !webURLIsValid || draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                            || (isLauncher && LauncherEditorPolicy.validationMessage(for: draft) != nil)
                    )
            }
            .padding(12)
            .background(.bar)
        }
        .task(id: draft.targetPath) {
            guard draft.kind == .app else {
                inspected = nil
                return
            }
            // A missing or unreadable target is not an error here: the row already shows "Target missing" and the
            // badge falls back to `Unknown`.
            do {
                inspected = try AppInspector().inspect(appAt: URL(fileURLWithPath: draft.targetPath))
            } catch {
                inspected = nil
            }
        }
        .alert("Duplicate Shortcut", isPresented: $isDuplicatePromptPresented) {
            TextField("New name", text: $duplicateName)
            Button("Cancel", role: .cancel) {}
            Button("Duplicate") { Task { await appState.duplicate(record, newName: duplicateName) } }
                .disabled(duplicateName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .confirmationDialog(
            "Export into a library folder?",
            isPresented: Binding(get: { pendingLibraryExport != nil }, set: { if !$0 { pendingLibraryExport = nil } }),
            titleVisibility: .visible,
            presenting: pendingLibraryExport
        ) { url in
            Button("Export Anyway") { startExport(to: url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text(appState.exportWarning(for: url) ?? "")
        }
        .sheet(item: $exportOutcome) { outcome in
            ExportSheet(
                exportedURL: outcome.exportedURL, environment: record.config.environment, arguments: record.config.arguments,
                trashedExisting: outcome.trashedExisting
            )
        }
        .sheet(isPresented: $isDiagnosticsPresented) {
            DiagnosticsView(record: record, profileCatalog: appState.profiles.catalog)
        }
        .sheet(isPresented: $isDeletePresented) {
            DeleteShortcutSheet(record: record, dataFolder: appState.dataFolderDeletionOption(for: record)) { request in
                await appState.delete(record, removeData: request.removeDataFolder, removeWebData: request.removeWebData)
            }
        }
    }

    private func save() {
        isSaving = true
        var config = draft
        if isWebApp {
            // The slug and bundle identifier stay on a rename (WebKit files the logins under the bundle id), and no icon
            // data is passed, so `regenerate` keeps the bundle's AppIcon.icns for `.copied` (Task 6 Deviation 2, A2).
            config = WebEditorPolicy.saveConfig(draft: draft, saved: record.config)
        } else if isLauncher {
            // Keeps the slug and bundle identifier on a rename, so a command's own HOME does not move.
            config = LauncherEditorPolicy.saveConfig(draft: draft, saved: record.config)
        } else {
            config.name = config.name.trimmingCharacters(in: .whitespaces)
            if config.name != record.config.name {
                // Final review M6: a rename steps around the slugs the other shortcuts use (this one's own stays free).
                config.slug = SlugAllocator.uniqueSlug(proposed: ShortcutConfig.slug(for: config.name),
                                                       taken: SlugAllocator.takenSlugs(in: appState.library.records, excluding: record.bundleURL))
                config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
            }
        }
        Task {
            // The written config can differ from the draft (trimmed name, a nil data path resolved to the default,
            // the current engine version), so adopt it; otherwise Save and Revert would stay enabled after saving.
            if await appState.save(record: record, config: config), let saved = appState.selectedRecord {
                draft = saved.config
            }
            isSaving = false
        }
    }

    private func exportPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.bundleURL.lastPathComponent
        panel.allowedContentTypes = [.applicationBundle]
        panel.canCreateDirectories = true
        // Never default to the library folder the shortcut lives in (final review I2).
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A copy directly inside a library folder would be scanned as a second shortcut; ask first (re-review Minor 5).
        if appState.exportWarning(for: url) != nil {
            pendingLibraryExport = url
        } else {
            startExport(to: url)
        }
    }

    private func startExport(to url: URL) {
        Task { exportOutcome = await appState.exportCopy(record, to: url) }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
