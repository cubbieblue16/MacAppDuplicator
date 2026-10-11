import CompatProfiles
import DuplicatorCore
import SwiftUI
import UniformTypeIdentifiers

struct IdentitySection: View {
    @Binding var draft: ShortcutConfig
    let record: ShortcutRecord
    /// The draft target's inspection; its icon file is the `.copied` preview.
    let inspected: InspectedApp?

    var body: some View {
        Section("Identity") {
            TextField("Name", text: $draft.name)
            Picker("Icon", selection: $draft.iconMode) {
                if draft.kind == .webApp {
                    // "Fetched from site" only while it is the saved mode: the editor cannot refetch an icon.
                    ForEach(WebEditorPolicy.iconModes(saved: record.config.iconMode), id: \.self) { mode in
                        Text(WebEditorPolicy.iconLabel(mode)).tag(mode)
                    }
                } else {
                    ForEach([IconMode.copied, .custom, .generated], id: \.self) { mode in
                        Text(LauncherEditorPolicy.iconLabel(mode, kind: draft.kind)).tag(mode)
                    }
                }
            }
            if draft.iconMode == .custom {
                LabeledContent("Icon file") {
                    HStack {
                        Text(draft.customIconPath ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Browse…") { chooseIcon() }
                    }
                }
            }
            LabeledContent("Preview") {
                IconPreview(source: IconPreviewSource.resolve(draft: draft, saved: record.config,
                                                              savedIconURL: record.iconURL,
                                                              targetIconURL: inspected?.iconFileURL))
            }
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.icns, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { draft.customIconPath = url.path }
    }
}

struct TargetSection: View {
    @Binding var draft: ShortcutConfig
    let inspected: InspectedApp?
    /// The compatibility profile for `draft.targetBundleIdentifier`, if any; it can turn the badge `Verified` or `Unsupported`.
    let profile: AppProfile?
    /// Why the last chosen target was refused (final review M5); the next accepted choice clears it.
    @State private var targetError: String?

    var body: some View {
        Section("Target") {
            LabeledContent("Application") {
                HStack {
                    Text(draft.targetPath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Browse…") { chooseTarget() }
                }
            }
            if let targetError {
                Label(targetError, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
            }
            LabeledContent("Bundle ID", value: draft.targetBundleIdentifier)
            if CompatBadge.isShown(for: draft.kind) {
                LabeledContent("Compatibility") {
                    Text(CompatBadge.badge(for: inspected, profile: profile).label)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            if let inspected, !inspected.warnings.isEmpty {
                ForEach(inspected.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Final review M5: a shortcut, this one included, is never a target.
        guard !TargetGuard.isShortcutBundle(at: url) else {
            targetError = TargetGuard.refusalMessage(forAppAt: url)
            return
        }
        guard let identifier = InstalledApps.infoDictionary(ofAppAt: url)?["CFBundleIdentifier"] as? String else { return }
        targetError = nil
        draft.targetPath = url.path
        draft.targetBundleIdentifier = identifier
    }
}

/// Read-only view of the compatibility profile for the draft's target (spec §8); it never edits the shortcut.
struct ProfileSection: View {
    let bundleIdentifier: String
    let profile: AppProfile?
    let detectedFamily: AppFamily?

    var body: some View {
        Section {
            if let profile {
                ProfileSummaryView(rows: ProfileSummary.rows(for: profile, detectedFamily: detectedFamily))
            } else {
                Text(verbatim: "No compatibility profile for \(bundleIdentifier).").foregroundStyle(.secondary)
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("A profile's arguments, environment and New Window command are copied into a shortcut only when it is created; Check Profile Updates never changes an existing shortcut.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LaunchSection: View {
    @Environment(AppState.self) private var appState
    @Binding var draft: ShortcutConfig
    let record: ShortcutRecord
    /// The editor's inspection of the current target; nil while it runs or when the target cannot be read.
    let inspected: InspectedApp?
    @State private var dataFolderError: String?
    /// A data folder waiting for the spec §4.3 destructive confirmation.
    @State private var pendingErase: PendingErase?
    /// Why Erase on quit stayed off or was turned off; cleared when the folder, the data mode or the toggle changes.
    @State private var eraseMessage: String?

    /// Erase on quit for a folder outside App Duplicator's data folder, waiting for the confirmation.
    private struct PendingErase {
        /// The folder the helper would empty after every quit.
        let dataPath: String
        /// True when the folder was chosen with Browse… while Erase on quit was on: confirming stores it and Cancel keeps
        /// the current folder. False when the toggle is being turned on for the current folder.
        let isNewFolder: Bool
    }

    var body: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultPath = ShortcutConfig.defaultDataPath(forSlug: draft.slug, home: home)
        let requiresSystemLaunch = inspected?.requiresSystemLaunch ?? false
        // Spec §4.5: the dark override exists only for these families; unknown targets get no promise either.
        let isForcedDarkAvailable = inspected?.family.supportsForcedDarkMode ?? false
        Section("Launch") {
            // Spec §4.1, the wizard's rule: a protected target always starts through System Launch, so the picker
            // shows what will happen and is locked. The stored value is left alone; the planner forces it at launch.
            Picker("Launch mode", selection: Binding(
                get: { requiresSystemLaunch ? LaunchMode.systemLaunch : draft.launchMode },
                set: { draft.launchMode = $0 }
            )) {
                Text("Dock Shortcut").tag(LaunchMode.dockShortcut)
                Text("System Launch").tag(LaunchMode.systemLaunch)
            }
            .disabled(requiresSystemLaunch)
            if let reason = inspected?.dockShortcutUnavailableReason {
                Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Data", selection: Binding(
                get: { draft.dataMode },
                set: { mode in
                    draft.dataMode = mode
                    // Erase on quit never runs without a data folder. Turning it off keeps the toggle truthful, and
                    // turning it on again later goes through `setEraseOnQuit`, confirmation included.
                    if mode == .disabled {
                        draft.eraseOnQuit = false
                    }
                    eraseMessage = nil
                }
            )) {
                Text("Auto").tag(DataMode.auto)
                Text("HOME override").tag(DataMode.homeOverride)
                Text("Disabled").tag(DataMode.disabled)
            }
            LabeledContent("Data folder") {
                HStack {
                    Text(draft.dataPath ?? defaultPath)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Browse…") { chooseDataFolder() }
                    if draft.dataPath != nil, draft.dataPath != defaultPath {
                        Button("Default") { useDataPath(nil, home: home) }
                    }
                }
            }
            .disabled(draft.dataMode == .disabled)
            if let dataFolderError {
                Label(dataFolderError, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
            if HelperEditorPolicy.helperControlsVisible(kind: draft.kind) {
                Toggle("Erase on quit", isOn: Binding(
                    get: { draft.eraseOnQuit },
                    set: { setEraseOnQuit($0, home: home) }
                ))
                .disabled(draft.dataMode == .disabled)
                .help("Empties the data folder every time the app quits, so every launch starts clean and signed out.")
                .alert(
                    HelperEditorPolicy.eraseConfirmationTitle,
                    isPresented: Binding(get: { pendingErase != nil }, set: { if !$0 { pendingErase = nil } }),
                    presenting: pendingErase
                ) { pending in
                    Button(HelperEditorPolicy.eraseConfirmButton, role: .destructive) { confirmErase(pending) }
                    Button("Cancel", role: .cancel) {}
                } message: { pending in
                    Text(verbatim: HelperEditorPolicy.eraseConfirmationMessage(name: draft.name, dataPath: pending.dataPath))
                }
                if draft.dataMode == .disabled {
                    Label(HelperEditorPolicy.disabledDataMessage, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                } else if let eraseMessage {
                    Label(eraseMessage, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                }
            }
            Picker("Appearance", selection: $draft.appearance) {
                Text("Follow System").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Force dark (Chromium/Electron only, best effort)").tag(Appearance.dark)
                    .disabled(!isForcedDarkAvailable)
            }
            if draft.appearance == .dark, let inspected, !inspected.family.supportsForcedDarkMode {
                Label(
                    "Force dark has no effect for this app: only Chromium, Electron and ToDesktop apps honour it. Choose Follow System or Light.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(.orange)
            }
            TextField("Language", text: Binding(
                get: { draft.languageCode ?? "" },
                set: { draft.languageCode = $0.isEmpty ? nil : $0 }
            ), prompt: Text("en"))
            .help("A language code like en, fr or pt-BR; blank follows the system language.")
            if let message = HelperEditorPolicy.languageValidation(draft.languageCode) {
                Label(message, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func chooseDataFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The same guard delete uses (final review I1): a folder that could never be trashed safely is never stored.
        switch appState.validateDataPath(url.path, targetPath: draft.targetPath, excluding: record.bundleURL, targetBundleIdentifier: draft.targetBundleIdentifier) {
        case .success:
            useDataPath(url.path, home: FileManager.default.homeDirectoryForCurrentUser)
        case .failure(let error):
            dataFolderError = error.localizedDescription
        }
    }

    /// Stores a new data folder (nil: the default folder). While Erase on quit is on, the folder goes through the check
    /// that turning the toggle on uses: a folder inside App Duplicator's data folder is stored at once, any other folder
    /// waits for the confirmation (Cancel keeps the current folder), and a folder the helper would never empty is stored
    /// with Erase on quit turned off and the reason shown.
    private func useDataPath(_ path: String?, home: URL) {
        dataFolderError = nil
        eraseMessage = nil
        guard draft.eraseOnQuit else {
            draft.dataPath = path
            return
        }
        let candidate = path ?? ShortcutConfig.defaultDataPath(forSlug: draft.slug, home: home)
        switch HelperEditorPolicy.eraseCheck(dataPath: candidate, dataMode: draft.dataMode, home: home) {
        case .allowed:
            draft.dataPath = path
        case .needsConfirmation(let dataPath):
            pendingErase = PendingErase(dataPath: dataPath, isNewFolder: true)
        case .refused(let message):
            draft.dataPath = path
            draft.eraseOnQuit = false
            eraseMessage = message
        }
    }

    /// Turning the toggle off always works; turning it on follows `HelperEditorPolicy.eraseCheck(for:home:)`.
    private func setEraseOnQuit(_ isOn: Bool, home: URL) {
        eraseMessage = nil
        guard isOn else {
            draft.eraseOnQuit = false
            return
        }
        switch HelperEditorPolicy.eraseCheck(for: draft, home: home) {
        case .allowed:
            draft.eraseOnQuit = true
        case .needsConfirmation(let dataPath):
            pendingErase = PendingErase(dataPath: dataPath, isNewFolder: false)
        case .refused(let message):
            eraseMessage = message
        }
    }

    /// The confirmation's destructive button: turns Erase on quit on and, for a folder chosen with Browse…, stores it.
    private func confirmErase(_ pending: PendingErase) {
        if pending.isNewFolder {
            draft.dataPath = pending.dataPath
        }
        draft.eraseOnQuit = true
        eraseMessage = nil
    }
}

/// Arguments, environment, and the spec §4.6 helper's menu bar icon and New Window command (spec §7). Erase on quit
/// lives in `LaunchSection`, beside the data folder it empties.
struct AdvancedSection: View {
    @Binding var draft: ShortcutConfig

    var body: some View {
        Section("Advanced") {
            LabeledContent("Arguments") {
                ArgumentsEditor(arguments: $draft.arguments)
            }
            EnvironmentTableView(environment: $draft.environment)
            if HelperEditorPolicy.helperControlsVisible(kind: draft.kind) {
                Toggle("Menu bar icon", isOn: $draft.menuBarIcon)
                    .help("Shows the app's icon in the menu bar while it runs, with Show, New Window and Quit.")
                TextField("New Window command", text: Binding(
                    get: { draft.newWindowCommand ?? "" },
                    set: { draft.newWindowCommand = $0.isEmpty ? nil : $0 }
                ), prompt: Text(verbatim: HelperEditorPolicy.newWindowPrompt))
                Text(verbatim: HelperEditorPolicy.newWindowHelp).font(.caption).foregroundStyle(.secondary)
                if let message = HelperEditorPolicy.newWindowValidation(draft.newWindowCommand) {
                    Label(message, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                } else if let note = HelperEditorPolicy.newWindowNote(for: draft, home: FileManager.default.homeDirectoryForCurrentUser) {
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(verbatim: HelperEditorPolicy.unavailableCaption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One argument per line, blank lines dropped. The typed text is kept as local state so Return can open a new line
/// (a binding that re-joins the parsed arguments would drop the trailing newline on every keystroke); the text is
/// rebuilt from `arguments` only when they change from outside, for example on Revert.
struct ArgumentsEditor: View {
    @Binding var arguments: [String]
    @State private var text: String

    init(arguments: Binding<[String]>) {
        _arguments = arguments
        _text = State(initialValue: arguments.wrappedValue.joined(separator: "\n"))
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .multilineTextAlignment(.leading)
            .frame(minHeight: 60)
            .help("One argument per line")
            .onChange(of: text) { _, newText in
                let parsed = Self.parse(newText)
                if parsed != arguments { arguments = parsed }
            }
            .onChange(of: arguments) { _, newArguments in
                if Self.parse(text) != newArguments { text = newArguments.joined(separator: "\n") }
            }
    }

    private static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// Phase 5: a file or folder shortcut's item and opener. Re-choosing keeps the kind (files for `.file`, folders for `.folder`).
struct FileSection: View {
    @Binding var draft: ShortcutConfig
    @State private var choiceError: String?

    var body: some View {
        Section(draft.kind == .folder ? "Folder" : "File") {
            LabeledContent("Opens") {
                HStack {
                    Text(draft.file?.path ?? "Nothing chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…", action: chooseItem)
                        .help(draft.kind == .folder ? "Choose the folder this shortcut opens" : "Choose the file this shortcut opens")
                }
            }
            LabeledContent("Open with") {
                HStack {
                    Text(draft.file?.openerAppPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Default app")
                    Button("Choose…", action: chooseOpener)
                        .help("Open the item with a specific app instead of its default app")
                    if draft.file?.openerAppPath != nil {
                        Button("Use Default") { draft.file?.openerAppPath = nil }
                            .help("Open the item with the app macOS picks for it")
                    }
                }
            }
            if let message = choiceError ?? LauncherEditorPolicy.validationMessage(for: draft) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func chooseItem() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = draft.kind == .file
        panel.canChooseDirectories = draft.kind == .folder
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !TargetGuard.isShortcutBundle(at: url) else {
            choiceError = TargetGuard.refusalMessage(forAppAt: url)
            return
        }
        choiceError = nil
        draft.file = FileConfig(path: FileConfig.normalizedPath(url.path), openerAppPath: draft.file?.openerAppPath)
    }

    private func chooseOpener() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !TargetGuard.isShortcutBundle(at: url) else {
            choiceError = TargetGuard.refusalMessage(forAppAt: url)
            return
        }
        choiceError = nil
        draft.file?.openerAppPath = FileConfig.normalizedPath(url.path)
    }
}

/// Phase 5: a command shortcut's program, arguments (one per line), working directory, terminal and own HOME.
struct CommandSection: View {
    @Binding var draft: ShortcutConfig
    @State private var argumentsText = ""

    var body: some View {
        Section("Command") {
            LabeledContent("Executable") {
                HStack {
                    TextField("Executable", text: executable, prompt: Text("/usr/local/bin/tool"))
                        .labelsHidden()
                        .help("The full path of the program or script to run")
                    Button("Choose…", action: chooseExecutable)
                        .help("Choose the program or script to run")
                }
            }
            LabeledContent("Arguments") {
                TextEditor(text: $argumentsText)
                    .font(.body.monospaced())
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 72)
                    .help("One argument per line. Spaces and quotes are passed exactly as typed; empty lines are ignored.")
            }
            TextField("Working directory", text: workingDirectory, prompt: Text("Default"))
                .help("The folder the command starts in")
            Picker("Terminal", selection: terminal) {
                ForEach(WizardModel.terminalChoices, id: \.self) { choice in
                    Text(WizardModel.terminalLabel(choice)).tag(choice)
                }
            }
            .help("Terminal and iTerm2 are driven through AppleScript, so macOS asks once for permission. No terminal runs the command in the background.")
            Toggle("Give this command its own HOME", isOn: homeOverride)
                .help("Runs the command with HOME set to a private folder under ~/Library/Application Support/App Duplicator")
            if let message = LauncherEditorPolicy.validationMessage(for: draft) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { argumentsText = draft.cli?.arguments.joined(separator: "\n") ?? "" }
        .onChange(of: argumentsText) { _, text in draft.cli?.arguments = WizardModel.parseArguments(text) }
    }

    private var executable: Binding<String> {
        Binding(get: { draft.cli?.executablePath ?? "" }, set: { draft.cli?.executablePath = $0 })
    }

    private var workingDirectory: Binding<String> {
        Binding(get: { draft.cli?.workingDirectory ?? "" }, set: { draft.cli?.workingDirectory = $0.isEmpty ? nil : $0 })
    }

    private var terminal: Binding<TerminalChoice> {
        Binding(get: { draft.cli?.terminal ?? .terminal }, set: { draft.cli?.terminal = $0 })
    }

    private var homeOverride: Binding<Bool> {
        Binding(get: { draft.cli?.homeOverride ?? false }, set: { draft.cli?.homeOverride = $0 })
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.cli?.executablePath = url.path
    }
}
