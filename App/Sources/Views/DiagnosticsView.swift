import DuplicatorCore
import SwiftUI

struct DiagnosticsModel {
    let shortcutName: String
    let bundlePath: String
    let targetPath: String
    let executablePath: String
    let launchMode: String
    let arguments: [String]
    let environment: [(key: String, value: String)]
    let warnings: [String]
    let logLines: [String]
    let planError: String?

    static func make(record: ShortcutRecord, logReader: LogReader = LogReader()) -> DiagnosticsModel {
        let logLines = logReader.tail(name: record.name)
        do {
            let config = record.config.resolvingDefaultDataPath(home: FileManager.default.homeDirectoryForCurrentUser)
            let preview = try LaunchPlanPreview.make(config: config, bundleURL: record.bundleURL)
            let env = preview.maskedEnvironment.keys.sorted().map { (key: $0, value: preview.maskedEnvironment[$0] ?? "") }
            return DiagnosticsModel(
                shortcutName: record.name,
                bundlePath: record.bundleURL.path,
                targetPath: record.config.targetPath,
                executablePath: preview.executablePath,
                launchMode: preview.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut",
                arguments: preview.arguments,
                environment: env,
                warnings: preview.warnings,
                logLines: logLines,
                planError: nil
            )
        } catch {
            return DiagnosticsModel(
                shortcutName: record.name,
                bundlePath: record.bundleURL.path,
                targetPath: record.config.targetPath,
                executablePath: "",
                launchMode: record.config.launchMode == .systemLaunch ? "System Launch" : "Dock Shortcut",
                arguments: [],
                environment: [],
                warnings: [],
                logLines: logLines,
                planError: error.localizedDescription
            )
        }
    }

    var reportText: String {
        var lines: [String] = []
        lines.append("App Duplicator diagnostics — \(shortcutName)")
        lines.append("Bundle: \(bundlePath)")
        lines.append("Target: \(targetPath)")
        if let planError {
            lines.append("Launch plan error: \(planError)")
        } else {
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
                            row("Target", model.targetPath)
                            if let error = model.planError {
                                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                            } else {
                                row("Executable", model.executablePath)
                                row("Launch mode", model.launchMode)
                            }
                        }
                        if model.planError == nil {
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
                Button("Open Log Folder") {
                    NSWorkspace.shared.open(LogReader().logFolder())
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .task {
            let record = record
            model = await Task.detached { DiagnosticsModel.make(record: record) }.value
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
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
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
