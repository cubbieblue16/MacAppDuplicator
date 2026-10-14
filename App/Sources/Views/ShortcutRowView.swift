import SwiftUI

struct ShortcutRowView: View {
    let record: ShortcutRecord
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name).lineLimit(1)
                    if record.needsRebuild {
                        Text("Needs rebuild")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                    }
                    if let reason = record.foreignReason {
                        // C3: a received or planted bundle; Save and Regenerate ask for a review first.
                        Text("Not created here")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.red.opacity(0.2), in: Capsule())
                            .help(Text(verbatim: reason))
                    }
                }
                subtitle
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer()
            if isRunning {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Running")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        if let url = record.iconURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if record.config.kind == .webApp {
            Text(record.webAppHost ?? "Web App").foregroundStyle(.secondary)
        } else if LauncherEditorPolicy.isLauncherKind(record.config.kind) {
            if record.targetExists {
                Text(LauncherEditorPolicy.subtitle(for: record.config)).foregroundStyle(.secondary)
            } else {
                Text("Item missing").foregroundStyle(.red)
            }
        } else if record.targetExists {
            let targetName = URL(fileURLWithPath: record.config.targetPath).deletingPathExtension().lastPathComponent
            Text([targetName, record.targetVersion].compactMap { $0 }.joined(separator: " "))
                .foregroundStyle(.secondary)
        } else {
            Text("Target missing").foregroundStyle(.red)
        }
    }
}
