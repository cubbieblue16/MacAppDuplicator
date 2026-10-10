import CompatProfiles
import DuplicatorCore
import SwiftUI

struct DiagnosticsModel {
    let shortcutName: String
    let bundlePath: String
    /// The bundle's `MADEngineVersion` (0 when missing); below `ShortcutConfig.currentEngineVersion` means Regenerate is due.
    let engineVersion: Int
    /// The profile match for the target bundle id (`ProfileSummary.matchLine`).
    let profileMatch: String
    /// The matched profile's rows (`ProfileSummary.rows`); empty without a match.
    let profileRows: [ProfileSummary.Row]
    /// The target path stored in the shortcut's config.
    let storedTargetPath: String
    /// The target the launcher would start (spec §7 "resolved target path"): the stored path while its bundle id
    /// still matches, else the Launch Services match for the bundle id (`TargetResolver`); nil when neither exists.
    let resolvedTargetPath: String?
    let executablePath: String
    let launchMode: String
    let arguments: [String]
    let environment: [(key: String, value: String)]
    let warnings: [String]
    let logLines: [String]
    let planError: String?
    /// Set for a web app: the facts the report shows instead of a target and a launch plan (nil for every other kind).
    /// The last stored property, with a default, so the two existing memberwise calls below stay as they are.
    var web: WebDetails?

    /// What a web app's Diagnostics shows. Every value is display text, so the view and the report share it.
    struct WebDetails: Equatable {
        /// The saved address with credentials, query and fragment removed (`redactedURL`).
        let url: String
        let userAgent: String
        /// `WebAppConfig.dataStoreID.uuidString`: the WebKit store name under `~/Library/WebKit/<bundle id>/WebsiteDataStore`.
        let dataStoreID: String
        /// `On` only when background mode is saved and the menu bar icon is on (the shell ignores it otherwise).
        let backgroundMode: String
        let menuBarIcon: String
        let badgePattern: String
        let extraHosts: [String]
        let zoom: String
    }

    static func make(record: ShortcutRecord, logReader: LogReader = LogReader(), profileCatalog: ProfileCatalog = .empty) -> DiagnosticsModel {
        // Lines a launcher built before argv masking wrote can hold secret argument values; mask them for display and
        // for the copied report.
        let logLines = logReader.tail(name: record.name).map(SecretMasking.maskLogLine)
        if record.config.kind == .webApp {
            return makeWeb(record: record, logLines: logLines)
        }
        let profile = profileCatalog.profile(forBundleIdentifier: record.config.targetBundleIdentifier)
        let profileMatch = ProfileSummary.matchLine(bundleIdentifier: record.config.targetBundleIdentifier, catalog: profileCatalog)
        var config = record.config.resolvingDefaultDataPath(home: FileManager.default.homeDirectoryForCurrentUser)
        let resolvedTarget: URL
        do {
            resolvedTarget = try TargetResolver().resolve(config: config)
        } catch {
            return failed(record: record, resolvedTargetPath: nil, logLines: logLines, profileMatch: profileMatch, profile: profile, error: error)
        }
        // Preview exactly what the launcher would inspect: the resolved bundle, not a stale stored path.
        config.targetPath = resolvedTarget.path
        do {
            let preview = try LaunchPlanPreview.make(config: config, bundleURL: record.bundleURL)
            let env = preview.maskedEnvironment.keys.sorted().map { (key: $0, value: preview.maskedEnvironment[$0] ?? "") }
            return DiagnosticsModel(
                shortcutName: record.name,
                bundlePath: record.bundleURL.path,
                engineVersion: record.engineVersion,
                profileMatch: profileMatch,
                profileRows: ProfileSummary.rows(for: profile, detectedFamily: preview.family),
                storedTargetPath: record.config.targetPath,
                resolvedTargetPath: resolvedTarget.path,
                executablePath: preview.executablePath,
                launchMode: preview.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut",
                arguments: preview.arguments,
                environment: env,
                warnings: preview.warnings,
                logLines: logLines,
                planError: nil
            )
        } catch {
            return failed(record: record, resolvedTargetPath: resolvedTarget.path, logLines: logLines, profileMatch: profileMatch, profile: profile, error: error)
        }
    }

    /// A web app has no target, profile or launch plan; the model carries its web settings instead.
    private static func makeWeb(record: ShortcutRecord, logLines: [String]) -> DiagnosticsModel {
        let config = record.config
        var model = DiagnosticsModel(
            shortcutName: record.name,
            bundlePath: record.bundleURL.path,
            engineVersion: record.engineVersion,
            profileMatch: "Not applicable (web app)",
            profileRows: [],
            storedTargetPath: "",
            resolvedTargetPath: nil,
            executablePath: "",
            launchMode: "Web Shell",
            arguments: [],
            environment: [],
            warnings: [],
            logLines: logLines,
            planError: config.webApp == nil ? "This web app has no web address saved. Regenerate the shortcut or recreate it." : nil
        )
        if let web = config.webApp {
            model.web = WebDetails(
                url: redactedURL(web.url),
                userAgent: web.userAgent == .chrome ? "Chrome" : "Safari",
                dataStoreID: web.dataStoreID.uuidString,
                backgroundMode: web.backgroundMode && config.menuBarIcon ? "On" : (web.backgroundMode ? "Off (needs the menu bar icon)" : "Off"),
                menuBarIcon: config.menuBarIcon ? "On" : "Off",
                badgePattern: badgePatternText(web.badgeRegex),
                extraHosts: web.extraHosts,
                zoom: WebEditorPolicy.zoomLabel(web.pageZoom)
            )
        } else {
            // Keep the web rows (never the native target rows) when the saved configuration lost its web section.
            let missing = "Not available (configuration missing)"
            model.web = WebDetails(
                url: missing, userAgent: missing, dataStoreID: missing, backgroundMode: missing, menuBarIcon: missing,
                badgePattern: missing, extraHosts: [missing], zoom: missing
            )
        }
        return model
    }

    /// `address` without credentials, query and fragment: the report is meant to be pasted into tickets (Deviation 5).
    static func redactedURL(_ address: String) -> String {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil, components.host != nil else { return "(unreadable address)" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "(unreadable address)"
    }

    /// The pattern the shell really matches titles with, and why when it is not the saved one.
    static func badgePatternText(_ configured: String?) -> String {
        let parser = BadgeTitleParser(pattern: configured)
        guard configured != nil else { return "\(parser.pattern) (default)" }
        return parser.usedFallbackPattern ? "\(parser.pattern) (the saved pattern is invalid; the default is used)" : parser.pattern
    }

    private static func failed(
        record: ShortcutRecord, resolvedTargetPath: String?, logLines: [String], profileMatch: String, profile: AppProfile?, error: Error
    ) -> DiagnosticsModel {
        DiagnosticsModel(
            shortcutName: record.name,
            bundlePath: record.bundleURL.path,
            engineVersion: record.engineVersion,
            profileMatch: profileMatch,
            profileRows: ProfileSummary.rows(for: profile, detectedFamily: nil),
            storedTargetPath: record.config.targetPath,
            resolvedTargetPath: resolvedTargetPath,
            executablePath: "",
            launchMode: record.config.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut",
            arguments: [],
            environment: [],
            warnings: [],
            logLines: logLines,
            planError: error.localizedDescription
        )
    }

    /// True when the launcher would start something other than the stored path (moved target or no target).
    var storedPathDiffers: Bool { resolvedTargetPath != storedTargetPath }

    var reportText: String {
        var lines: [String] = []
        lines.append("App Duplicator diagnostics — \(shortcutName)")
        lines.append("Bundle: \(bundlePath)")
        lines.append("Engine version: \(engineVersion) (current \(ShortcutConfig.currentEngineVersion))")
        if let web {
            lines.append("Kind: Web app")
            lines.append("URL: \(web.url)")
            lines.append("User agent: \(web.userAgent)")
            lines.append("Data store id: \(web.dataStoreID)")
            lines.append("Background: \(web.backgroundMode)")
            lines.append("Menu bar icon: \(web.menuBarIcon)")
            lines.append("Badge pattern: \(web.badgePattern)")
            lines.append("Also open in app: \(web.extraHosts.isEmpty ? "none" : web.extraHosts.joined(separator: ", "))")
            lines.append("Zoom: \(web.zoom)")
        } else {
            lines.append("Profile: \(profileMatch)")
            lines.append(contentsOf: profileRows.map { "  \($0.label): \($0.value)" })
            lines.append("Target: \(resolvedTargetPath ?? "not found")")
            if storedPathDiffers {
                lines.append("Stored target path: \(storedTargetPath)")
            }
        }
        if let planError {
            lines.append("Launch plan error: \(planError)")
        } else if web == nil {
            lines.append("Executable: \(executablePath)")
            lines.append("Launch mode: \(launchMode)")
            lines.append("")
            lines.append("Arguments:")
            lines.append(contentsOf: arguments.map { "  \($0)" })
            lines.append("")
            lines.append("Environment:")
            lines.append(contentsOf: environment.map { "  \($0.key)=\($0.value)" })
            if !warnings.isEmpty {
                lines.append("")
                lines.append("Warnings:")
                lines.append(contentsOf: warnings.map { "  \($0)" })
            }
        }
        lines.append("")
        lines.append("Recent log (last \(logLines.count) lines):")
        lines.append(contentsOf: logLines)
        return lines.joined(separator: "\n")
    }
}

struct DiagnosticsView: View {
    let record: ShortcutRecord
    /// The profiles in use when the sheet opened (`AppState.profiles.catalog`).
    let profileCatalog: ProfileCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var model: DiagnosticsModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics — \(record.name)").font(.headline)
            if let model {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Shortcut") {
                            row("Bundle", model.bundlePath)
                            row("Engine", "\(model.engineVersion) (current \(ShortcutConfig.currentEngineVersion))")
                            if let web = model.web {
                                row("Kind", "Web app")
                                row("URL", web.url)
                                row("User agent", web.userAgent)
                                row("Data store", web.dataStoreID)
                                row("Background", web.backgroundMode)
                                row("Menu bar icon", web.menuBarIcon)
                                row("Badge pattern", web.badgePattern)
                                row("Also open", web.extraHosts.isEmpty ? "None" : web.extraHosts.joined(separator: ", "))
                                row("Zoom", web.zoom)
                            } else {
                                row("Profile", model.profileMatch)
                                row("Target", model.resolvedTargetPath ?? "Not found")
                                if model.storedPathDiffers {
                                    row("Stored path", model.storedTargetPath)
                                }
                            }
                            if let error = model.planError {
                                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                            } else if model.web == nil {
                                row("Executable", model.executablePath)
                                row("Launch mode", model.launchMode)
                            }
                        }
                        if !model.profileRows.isEmpty {
                            section("Profile") { ProfileSummaryView(rows: model.profileRows) }
                        }
                        if model.planError == nil, model.web == nil {
                            section("Arguments") { mono(model.arguments.joined(separator: "\n")) }
                            section("Environment") { mono(model.environment.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")) }
                            if !model.warnings.isEmpty {
                                section("Warnings") {
                                    ForEach(model.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
                                }
                            }
                        }
                        section("Recent log (last 200 lines)") { mono(model.logLines.joined(separator: "\n")) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Copy Report") {
                    guard let model else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.reportText, forType: .string)
                }
                .disabled(model == nil)
                Button("Open Log Folder") { LogFolderOpener.open() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .task {
            let record = record
            let profileCatalog = profileCatalog
            model = await Task.detached { DiagnosticsModel.make(record: record, profileCatalog: profileCatalog) }.value
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
