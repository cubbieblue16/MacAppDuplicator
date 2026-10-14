import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: URL?

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarSection.allCases) { section in
                let records = section.records(in: appState.library)
                if !records.isEmpty || section == .apps {
                    Section(section.rawValue) {
                        ForEach(records) { record in
                            ShortcutRowView(record: record, isRunning: appState.library.isRunning(record))
                                .tag(record.bundleURL)
                                .contextMenu { rowMenu(record) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if !appState.library.warnings.isEmpty {
                VStack {
                    Spacer()
                    Label("\(appState.library.warnings.count) unreadable bundle(s) skipped", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(appState.library.warnings.joined(separator: "\n"))
                        .padding(8)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Shortcuts built before install tokens stay reviewable after Not now (`LegacyTrustReviewSheet`).
            let count = appState.library.legacyCandidates.count
            if count > 0 {
                HStack(spacing: 8) {
                    Label(Self.legacyBannerText(count: count), systemImage: "hand.raised")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Review…") { Task { await appState.reviewLegacyShortcuts() } }
                        .controlSize(.small)
                }
                .padding(8)
                .background(.bar)
            }
        }
    }

    static func legacyBannerText(count: Int) -> String {
        count == 1
            ? "1 shortcut from an earlier version needs review"
            : "\(count) shortcuts from an earlier version need review"
    }

    @ViewBuilder
    private func rowMenu(_ record: ShortcutRecord) -> some View {
        Button("Launch") { Task { await appState.launch(record) } }
        Button("Reveal in Finder") { appState.reveal(record) }
        Divider()
        Button("Regenerate") { Task { await appState.regenerate(record) } }
    }
}
