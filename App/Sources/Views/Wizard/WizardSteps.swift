import DuplicatorCore
import SwiftUI
import UniformTypeIdentifiers

struct KindStep: View {
    @Bindable var model: WizardModel

    private struct Option { let kind: ShortcutKind; let title: String; let subtitle: String; let enabled: Bool; let symbol: String }
    private let options = [
        Option(kind: .app, title: "Application", subtitle: "Run a second copy of an installed app with its own data", enabled: true, symbol: "app.badge"),
        Option(kind: .webApp, title: "Web App", subtitle: "Coming in a later phase", enabled: false, symbol: "globe"),
        Option(kind: .folder, title: "File or Folder", subtitle: "Coming in a later phase", enabled: false, symbol: "folder"),
        Option(kind: .cli, title: "Command", subtitle: "Coming in a later phase", enabled: false, symbol: "terminal"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want to duplicate?").font(.title3)
            ForEach(options, id: \.kind) { option in
                Button {
                    model.kind = option.kind
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.symbol).font(.title2).frame(width: 32)
                        VStack(alignment: .leading) {
                            Text(option.title)
                            Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.kind == option.kind { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    }
                    .padding(10)
                    .background(model.kind == option.kind ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!option.enabled)
            }
        }
    }
}

struct TargetStep: View {
    @Bindable var model: WizardModel
    @State private var apps: [InstalledApp] = []
    @State private var query = ""
    @State private var selection: URL?

    private var filtered: [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose the application").font(.title3)
            TextField("Search applications", text: $query)
                .textFieldStyle(.roundedBorder)
            InstalledAppsGrid(apps: filtered, selection: $selection)
                .frame(minHeight: 220)
            AppDropZone(onDrop: { select($0) }, onBrowse: browse)
            if let error = model.inspectError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
            }
            if let app = model.inspected {
                Text("\(app.name) \(app.version) · \(CompatBadge.badge(for: app).label)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            apps = await Task.detached { InstalledApps.scan() }.value
            selection = model.targetURL
        }
        .onChange(of: selection) { _, url in
            if let url, url != model.targetURL { model.selectTarget(url) }
        }
    }

    private func select(_ url: URL) {
        selection = url
        model.selectTarget(url)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }
}

struct IdentityStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        Form {
            Text("Name and icon").font(.title3)
            TextField("Name", text: $model.name)
                .help("This becomes the Dock title and the bundle name")
            Picker("Icon", selection: $model.iconMode) {
                Text("Copied from target").tag(IconMode.copied)
                Text("Custom file…").tag(IconMode.custom)
                Text("Generated tile").tag(IconMode.generated)
            }
            if model.iconMode == .custom {
                LabeledContent("Icon file") {
                    HStack {
                        Text(model.customIconPath ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseIcon() }
                    }
                }
            }
            LabeledContent("Preview") { preview.frame(width: 96, height: 96) }
            Picker("Launch mode", selection: $model.launchMode) {
                Text("Dock Shortcut").tag(LaunchMode.dockShortcut)
                Text("System Launch").tag(LaunchMode.systemLaunch)
            }
            .disabled(model.requiresSystemLaunch)
            .help(model.requiresSystemLaunch ? "This app is protected by launch constraints; System Launch is required" : "")
        }
        .formStyle(.columns)
    }

    @ViewBuilder
    private var preview: some View {
        switch model.iconMode {
        case .copied:
            if let url = model.inspected?.iconFileURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable()
            } else if let target = model.targetURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: target.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        case .custom:
            if let path = model.customIconPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
            }
        case .generated:
            Image(decorative: IconRenderer.generatedTile(initials: IconRenderer.initials(for: model.name), size: 192), scale: 2)
                .resizable()
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.icns, .png, .jpeg, .tiff]
        if panel.runModal() == .OK, let url = panel.url { model.customIconPath = url.path }
    }
}

struct DataStep: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: WizardModel
    @State private var dataFolderError: String?

    private var slug: String { ShortcutConfig.slug(for: model.name.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where does its data live?").font(.title3)
            Picker("Data", selection: $model.dataMode) {
                option("Auto", "Native apps get a separate HOME; Electron and Chromium apps get a separate user-data folder").tag(DataMode.auto)
                option("HOME override", "Always run with a separate HOME folder").tag(DataMode.homeOverride)
                option("Disabled", "Share data with the original app. Two copies may conflict.").tag(DataMode.disabled)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            LabeledContent("Data folder") {
                HStack {
                    Text(model.dataPath ?? ShortcutConfig.defaultDataPath(forSlug: slug, home: FileManager.default.homeDirectoryForCurrentUser))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { choose() }
                    if model.dataPath != nil {
                        Button("Default") {
                            model.dataPath = nil
                            dataFolderError = nil
                        }
                    }
                }
            }
            .disabled(model.dataMode == .disabled)
            if let dataFolderError {
                Label(dataFolderError, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
            Text("Default: ~/Library/Application Support/App Duplicator/\(slug)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func option(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The same guard delete uses (final review I1); a new shortcut has no bundle of its own to exclude yet.
        switch appState.validateDataPath(url.path, targetPath: model.targetURL?.path ?? "", excluding: nil) {
        case .success:
            model.dataPath = url.path
            dataFolderError = nil
        case .failure(let error):
            dataFolderError = error.localizedDescription
        }
    }
}

struct ReviewStep: View {
    let model: WizardModel
    @State private var showPlan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review").font(.title3)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Name", model.name)
                row("Target", model.targetURL?.path ?? "")
                row("Compatibility", CompatBadge.badge(for: model.inspected).label)
                row("Launch mode", model.requiresSystemLaunch || model.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut")
                row("Data", dataDescription)
                row("Icon", iconDescription)
            }
            if let error = model.previewError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
            }
            if let preview = model.preview {
                DisclosureGroup("Launch plan", isExpanded: $showPlan) {
                    VStack(alignment: .leading, spacing: 6) {
                        planRow("Executable", preview.executablePath)
                        planRow("Arguments", preview.arguments.joined(separator: "\n"))
                        planRow("Environment additions", preview.environmentAdditions.keys.sorted().map { "\($0)=\(preview.environmentAdditions[$0] ?? "")" }.joined(separator: "\n"))
                        if !preview.warnings.isEmpty {
                            Text("Warnings").font(.caption).foregroundStyle(.secondary)
                            ForEach(preview.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption) }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var dataDescription: String {
        switch model.dataMode {
        case .auto: "Auto"
        case .homeOverride: "HOME override"
        case .disabled: "Disabled"
        }
    }

    private var iconDescription: String {
        switch model.iconMode {
        case .copied: "Copied from target"
        case .custom: model.customIconPath.map { "Custom: \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Custom file…"
        case .generated: "Generated tile"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func planRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}
