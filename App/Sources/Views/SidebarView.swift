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
    }

    @ViewBuilder
    private func rowMenu(_ record: ShortcutRecord) -> some View {
        Button("Launch") { Task { await appState.launch(record) } }
        Button("Reveal in Finder") { appState.reveal(record) }
        Divider()
        Button("Regenerate") { Task { await appState.regenerate(record) } }
    }
}
