import DuplicatorCore
import SwiftUI
import UniformTypeIdentifiers

struct IdentitySection: View {
    @Binding var draft: ShortcutConfig
    let record: ShortcutRecord

    var body: some View {
        Section("Identity") {
            TextField("Name", text: $draft.name)
            Picker("Icon", selection: $draft.iconMode) {
                Text("Copied from target").tag(IconMode.copied)
                Text("Custom file…").tag(IconMode.custom)
                Text("Generated tile").tag(IconMode.generated)
            }
            if draft.iconMode == .custom {
                LabeledContent("Icon file") {
                    HStack {
                        Text(draft.customIconPath ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseIcon() }
                    }
                }
            }
            LabeledContent("Preview") {
                if let url = record.iconURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 64, height: 64)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 48)).foregroundStyle(.secondary).frame(width: 64, height: 64)
                }
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

    var body: some View {
        Section("Target") {
            LabeledContent("Application") {
                HStack {
                    Text(draft.targetPath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Choose…") { chooseTarget() }
                }
            }
            LabeledContent("Bundle ID", value: draft.targetBundleIdentifier)
            LabeledContent("Compatibility") {
                Text(CompatBadge.badge(for: inspected).label)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
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
        guard panel.runModal() == .OK, let url = panel.url,
              let identifier = InstalledApps.infoDictionary(ofAppAt: url)?["CFBundleIdentifier"] as? String else { return }
        draft.targetPath = url.path
        draft.targetBundleIdentifier = identifier
    }
}

struct LaunchSection: View {
    @Binding var draft: ShortcutConfig

    var body: some View {
        let defaultPath = ShortcutConfig.defaultDataPath(forSlug: draft.slug, home: FileManager.default.homeDirectoryForCurrentUser)
        Section("Launch") {
            Picker("Launch mode", selection: $draft.launchMode) {
                Text("Dock Shortcut").tag(LaunchMode.dockShortcut)
                Text("System Launch").tag(LaunchMode.systemLaunch)
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
                    Button("Choose…") { chooseDataFolder() }
                    if draft.dataPath != nil, draft.dataPath != defaultPath { Button("Default") { draft.dataPath = nil } }
                }
            }
            .disabled(draft.dataMode == .disabled)
            Picker("Appearance", selection: $draft.appearance) {
                Text("System").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
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
        if panel.runModal() == .OK, let url = panel.url { draft.dataPath = url.path }
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
