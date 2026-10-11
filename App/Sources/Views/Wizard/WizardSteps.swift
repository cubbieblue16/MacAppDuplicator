import CompatProfiles
import DuplicatorCore
import SwiftUI
import UniformTypeIdentifiers

struct KindStep: View {
    @Bindable var model: WizardModel

    private struct Option { let kind: ShortcutKind; let title: String; let subtitle: String; let enabled: Bool; let symbol: String }
    private let options = [
        Option(kind: .app, title: "Application", subtitle: "Run a second copy of an installed app with its own data", enabled: true, symbol: "app.badge"),
        Option(kind: .webApp, title: "Web App", subtitle: "Any website as its own app", enabled: true, symbol: "globe"),
        Option(kind: .folder, title: "File or Folder", subtitle: "Open a document or folder from the Dock", enabled: true, symbol: "folder"),
        Option(kind: .cli, title: "Command", subtitle: "Run a program or script, in a terminal or in the background", enabled: true, symbol: "terminal"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want to duplicate?").font(.title3)
            ForEach(options, id: \.kind) { option in
                Button {
                    model.chooseKind(option.kind)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.symbol).font(.title2).frame(width: 32)
                        VStack(alignment: .leading) {
                            Text(option.title)
                            Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isSelected(option) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    }
                    .padding(10)
                    .background(isSelected(option) ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!option.enabled)
            }
        }
    }

    /// "File or Folder" is offered as `.folder` but stays selected once a chosen file made the kind `.file`.
    private func isSelected(_ option: Option) -> Bool {
        option.kind == .folder ? (model.kind == .file || model.kind == .folder) : model.kind == option.kind
    }
}

struct TargetStep: View {
    @Bindable var model: WizardModel
    @State private var apps: [InstalledApp] = []
    @State private var query = ""
    @State private var selection: URL?

    private var filtered: [InstalledApp] { WizardModel.filteredApps(apps, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose the application").font(.title3)
            TextField("Search applications", text: $query)
                .textFieldStyle(.roundedBorder)
            if WizardModel.showsNoMatches(apps: apps, query: query) {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                       description: Text("No installed app matches “\(query)”. Drop the app below or browse for it."))
                    .frame(minHeight: 220)
            } else {
                InstalledAppsGrid(apps: filtered, selection: $selection)
                    .frame(minHeight: 220)
            }
            AppDropZone(onDrop: { select($0) }, onBrowse: browse)
            if let error = model.inspectError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
            }
            if let app = model.inspected, CompatBadge.isShown(for: model.kind) {
                Text("\(app.name) \(app.version) · \(CompatBadge.badge(for: app, profile: model.profile).label)")
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
                Text(model.copiedIconLabel).tag(IconMode.copied)
                Text("Custom file").tag(IconMode.custom)
                Text("Generated tile").tag(IconMode.generated)
            }
            if model.iconMode == .custom {
                LabeledContent("Icon file") {
                    HStack {
                        Text(model.customIconPath ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Browse…") { chooseIcon() }
                    }
                }
            }
            LabeledContent("Preview") { preview.frame(width: 96, height: 96) }
            if model.kind == .webApp, let status = model.webIconStatusText {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if model.kind == .app {
                Picker("Launch mode", selection: $model.launchMode) {
                    Text("Dock Shortcut").tag(LaunchMode.dockShortcut)
                    Text("System Launch").tag(LaunchMode.systemLaunch)
                }
                .disabled(model.requiresSystemLaunch)
                .help(model.requiresSystemLaunch ? "This app is protected by launch constraints; System Launch is required" : "")
            }
        }
        .formStyle(.columns)
    }

    /// A launcher's Copied icon is the Finder icon of its item or executable, the same image the builder renders.
    @ViewBuilder private var launcherIconPreview: some View {
        if let path = model.launcherIconPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: "app.dashed").resizable()
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch model.iconMode {
        case .copied:
            if model.isLauncherKind { launcherIconPreview } else if model.kind == .webApp {
                if let data = model.webIconData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if model.webIconFetchState == .fetching {
                    ProgressView().accessibilityLabel("Fetching icon")
                } else {
                    generatedTile
                }
            } else if let url = model.inspected?.iconFileURL, let image = NSImage(contentsOf: url) {
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
            generatedTile
        }
    }

    private var generatedTile: some View {
        Image(decorative: IconRenderer.generatedTile(initials: IconRenderer.initials(for: model.name), size: 192), scale: 2)
            .resizable()
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

    private var slug: String { model.slug }

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
                    Button("Browse…") { choose() }
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
        switch appState.validateDataPath(url.path, targetPath: model.targetURL?.path ?? "", excluding: nil, targetBundleIdentifier: model.inspected?.bundleIdentifier) {
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
    @State private var showProfile = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review").font(.title3)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    if model.kind == .webApp {
                        ForEach(model.webReviewRows, id: \.label) { row($0.label, $0.value) }
                    } else if model.isLauncherKind {
                        ForEach(model.launcherReviewRows, id: \.label) { row($0.label, $0.value) }
                    } else {
                        row("Name", model.name)
                        row("Target", model.targetURL?.path ?? "")
                        if CompatBadge.isShown(for: model.kind) {
                            row("Compatibility", CompatBadge.badge(for: model.inspected, profile: model.profile).label)
                        }
                        row("Profile", model.profile.map { "\($0.name) · \(ProfileSummary.statusLabel($0.status))" } ?? "None")
                        row("Launch mode", model.requiresSystemLaunch || model.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut")
                        row("Data", dataDescription)
                        row("Icon", model.iconDescription)
                    }
                }
                if model.kind == .webApp, let status = model.webIconStatusText {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.previewError {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
                }
                if model.kind == .app, let profile = model.profile {
                    DisclosureGroup("Profile defaults", isExpanded: $showProfile) {
                        VStack(alignment: .leading, spacing: 6) {
                            ProfileSummaryView(rows: ProfileSummary.rows(for: profile, detectedFamily: model.inspected?.family))
                            Text("The profile's arguments, environment and New Window command are copied into the new shortcut; change them in its Advanced section after it is created.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                if let preview = model.preview {
                    DisclosureGroup("Launch plan", isExpanded: $showPlan) {
                        VStack(alignment: .leading, spacing: 6) {
                            planRow("Executable", preview.executablePath)
                            planRow("Arguments", preview.arguments.joined(separator: "\n"))
                            planRow("Environment additions", preview.environmentAdditions.keys.sorted().map { "\($0)=\(preview.environmentAdditions[$0] ?? "")" }.joined(separator: "\n"))
                            if let helper = preview.helper {
                                planRow("Helper", helper)
                            }
                            if !preview.warnings.isEmpty {
                                Text("Warnings").font(.caption).foregroundStyle(.secondary)
                                ForEach(preview.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption) }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dataDescription: String {
        switch model.dataMode {
        case .auto: "Auto"
        case .homeOverride: "HOME override"
        case .disabled: "Disabled"
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
