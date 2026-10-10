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
    @State private var exportedURL: URL?
    @State private var isDeletePresented = false
    @State private var isDiagnosticsPresented = false

    init(record: ShortcutRecord) {
        self.record = record
        _draft = State(initialValue: record.config)
    }

    private var hasChanges: Bool { draft != record.config }

    var body: some View {
        Form {
            IdentitySection(draft: $draft, record: record)
            TargetSection(draft: $draft, inspected: inspected)
            LaunchSection(draft: $draft, record: record)
            AdvancedSection(draft: $draft)
            Section("Actions") {
                HStack {
                    Button("Launch") { Task { await appState.launch(record) } }
                        .disabled(!record.targetExists)
                    Button("Reveal in Finder") { appState.reveal(record) }
                    Button("Regenerate") { Task { await appState.regenerate(record) } }
                    Button("Duplicate…") {
                        duplicateName = "\(record.name) Copy"
                        isDuplicatePromptPresented = true
                    }
                    Button("Export…") { exportPanel() }
                    Button("Diagnostics…") { isDiagnosticsPresented = true }
                    Button("Delete…", role: .destructive) { isDeletePresented = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(record.name)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if record.needsRebuild {
                    Label("Built with an older launcher. Regenerate to update.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { draft = record.config }.disabled(!hasChanges || isSaving)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || isSaving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
        .task(id: draft.targetPath) {
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
        .sheet(item: $exportedURL) { url in
            ExportSheet(exportedURL: url)
        }
        .sheet(isPresented: $isDiagnosticsPresented) {
            DiagnosticsView(record: record)
        }
        .sheet(isPresented: $isDeletePresented) {
            DeleteShortcutSheet(record: record, dataFolder: appState.dataFolderDeletionOption(for: record)) { removeData in
                await appState.delete(record, removeData: removeData)
            }
        }
    }

    private func save() {
        isSaving = true
        var config = draft
        config.name = config.name.trimmingCharacters(in: .whitespaces)
        if config.name != record.config.name {
            config.slug = ShortcutConfig.slug(for: config.name)
            config.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: config.slug)
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
        Task {
            if await appState.export(record, to: url) { exportedURL = url }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
