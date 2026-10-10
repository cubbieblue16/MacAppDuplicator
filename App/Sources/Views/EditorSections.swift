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
                    Text("Copied from target").tag(IconMode.copied)
                    Text("Custom file").tag(IconMode.custom)
                    Text("Generated tile").tag(IconMode.generated)
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
            Text("A profile's arguments and environment are copied into a shortcut only when it is created; Check Profile Updates never changes an existing shortcut.")
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

    var body: some View {
        let defaultPath = ShortcutConfig.defaultDataPath(forSlug: draft.slug, home: FileManager.default.homeDirectoryForCurrentUser)
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
            Picker("Data", selection: $draft.dataMode) {
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
                        Button("Default") {
                            draft.dataPath = nil
                            dataFolderError = nil
                        }
                    }
                }
            }
            .disabled(draft.dataMode == .disabled)
            if let dataFolderError {
                Label(dataFolderError, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
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
            .help("Two-letter language code, blank for system")
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
            draft.dataPath = url.path
            dataFolderError = nil
        case .failure(let error):
            dataFolderError = error.localizedDescription
        }
    }
}

struct AdvancedSection: View {
    @Binding var draft: ShortcutConfig

    var body: some View {
        Section("Advanced") {
            LabeledContent("Arguments") {
                ArgumentsEditor(arguments: $draft.arguments)
            }
            EnvironmentTableView(environment: $draft.environment)
            Toggle("Erase data on quit", isOn: $draft.eraseOnQuit).disabled(true).help("Coming in Phase 6")
            Toggle("Menu bar icon", isOn: $draft.menuBarIcon).disabled(true).help("Coming in Phase 6")
            // GC-22: the editor says inline that these settings are stored but inert until Phase 6.
            Text("Stored now; takes effect in Phase 6").font(.caption).foregroundStyle(.secondary)
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
