import DuplicatorCore
import SwiftUI

/// The editor's section for a web app (skeleton decision 16): address, user agent, badge pattern, extra hosts, the
/// live menu bar options, the remembered zoom (read-only) and the web data row. It edits the draft only; Save writes
/// it through `WebEditorPolicy.saveConfig`.
struct WebAppSection: View {
    @Environment(AppState.self) private var appState
    @Binding var draft: ShortcutConfig
    /// The saved record: Remove Web Data acts on its store, never on an unsaved draft.
    let record: ShortcutRecord
    /// False while the address field holds something that is not an https address; the editor disables Save then.
    @Binding var urlIsValid: Bool

    @State private var urlText: String
    @State private var urlMessage: String?
    @State private var badgeText: String
    @State private var isRemoveConfirmationPresented = false
    @State private var isRemoving = false
    @State private var didRemove = false

    init(draft: Binding<ShortcutConfig>, record: ShortcutRecord, urlIsValid: Binding<Bool>) {
        _draft = draft
        self.record = record
        _urlIsValid = urlIsValid
        _urlText = State(initialValue: draft.wrappedValue.webApp?.url ?? "")
        _badgeText = State(initialValue: draft.wrappedValue.webApp?.badgeRegex ?? "")
    }

    var body: some View {
        Section("Web App") {
            if let web = Binding($draft.webApp) {
                TextField("Website URL", text: $urlText, prompt: Text("https://example.com"))
                    .onChange(of: urlText) { _, text in applyURL(text) }
                if let urlMessage {
                    Label(urlMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Picker("User agent", selection: web.userAgent) {
                    Text("Safari").tag(UserAgentPreset.safari)
                    Text("Chrome").tag(UserAgentPreset.chrome)
                }
                TextField("Badge pattern", text: $badgeText, prompt: Text(BadgeTitleParser.defaultPattern))
                    .font(.body.monospaced())
                    .onChange(of: badgeText) { _, text in
                        let pattern = WebEditorPolicy.badgePattern(from: text)
                        if draft.webApp?.badgeRegex != pattern { draft.webApp?.badgeRegex = pattern }
                    }
                if let warning = WebEditorPolicy.badgeWarning(for: badgeText) {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else {
                    caption("The first capture group of this pattern is read from the page title as the unread count. Leave blank for the default.")
                }
                LabeledContent("Also open in app") { HostsEditor(hosts: web.extraHosts) }
                caption("One host per line. Links to these hosts, and their subdomains, open inside the web app instead of your browser.")

                Toggle("Menu bar icon", isOn: $draft.menuBarIcon)
                    .onChange(of: draft.menuBarIcon) { _, isOn in
                        if !isOn, draft.webApp?.backgroundMode == true { draft.webApp?.backgroundMode = false }
                    }
                caption("Active for web apps: the icon appears the next time the web app starts.")
                Toggle("Keep running in the menu bar when the window closes", isOn: web.backgroundMode)
                    .disabled(!draft.menuBarIcon)
                if !draft.menuBarIcon { caption("Turn on the menu bar icon first") }

                LabeledContent("Zoom") {
                    Text(WebEditorPolicy.zoomLabel(web.wrappedValue.pageZoom)).foregroundStyle(.secondary)
                }
                caption("Read-only. The web app remembers the zoom you set inside it.")

                LabeledContent("Web data") {
                    Text(web.wrappedValue.dataStoreID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button("Remove Web Data…") { isRemoveConfirmationPresented = true }.disabled(isRemoving)
                    if didRemove { Label("Web data removed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                }
                caption("Logins, cookies, cache and local storage for this web app. Save never changes them.")
            }
        }
        .onChange(of: draft.webApp?.url) { _, newURL in
            // The draft changed from outside (Save adopting the written config): show it unless the field already says it.
            guard let newURL else { return }
            switch WebEditorPolicy.validatedURL(urlText) {
            case .success(let current) where current == newURL: break
            default:
                urlText = newURL
                urlMessage = nil
                urlIsValid = true
            }
        }
        .onChange(of: draft.webApp?.badgeRegex) { _, newPattern in
            if WebEditorPolicy.badgePattern(from: badgeText) != newPattern { badgeText = newPattern ?? "" }
        }
        .confirmationDialog(
            "Remove web data for “\(record.name)”?",
            isPresented: $isRemoveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Web Data", role: .destructive) { removeWebData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(WebEditorPolicy.removeWebDataMessage(shortcutName: record.name))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func applyURL(_ text: String) {
        switch WebEditorPolicy.validatedURL(text) {
        case .success(let url):
            urlMessage = nil
            urlIsValid = true
            if draft.webApp?.url != url { draft.webApp?.url = url }
        case .failure(let error):
            urlMessage = error.localizedDescription
            urlIsValid = false
        }
    }

    private func removeWebData() {
        isRemoving = true
        didRemove = false
        Task {
            didRemove = await appState.removeWebData(for: record)
            isRemoving = false
        }
    }
}

/// One host per line, blank lines dropped. Same local-text pattern as `ArgumentsEditor`: the typed text is kept so Return
/// can open a new line, and rebuilt from `hosts` only when they change from outside (Revert).
struct HostsEditor: View {
    @Binding var hosts: [String]
    @State private var text: String

    init(hosts: Binding<[String]>) {
        _hosts = hosts
        _text = State(initialValue: hosts.wrappedValue.joined(separator: "\n"))
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .frame(minHeight: 60)
            .help("One host per line, for example accounts.example.com")
            .onChange(of: text) { _, newText in
                let parsed = WebEditorPolicy.parsedHosts(from: newText)
                if parsed != hosts { hosts = parsed }
            }
            .onChange(of: hosts) { _, newHosts in
                if WebEditorPolicy.parsedHosts(from: text) != newHosts { text = newHosts.joined(separator: "\n") }
            }
    }
}
