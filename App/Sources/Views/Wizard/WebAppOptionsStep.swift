import DuplicatorCore
import SwiftUI

/// Wizard step `Web App Options` (replaces the Data step for web apps). Copy is verbatim from the Phase 4 skeleton,
/// decision 16.
struct WebAppOptionsStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        Form {
            Text("Web App Options").font(.title3)
            Picker("User agent", selection: $model.userAgent) {
                Text("Safari").tag(UserAgentPreset.safari)
                Text("Chrome").tag(UserAgentPreset.chrome)
            }
            TextField("Badge pattern", text: $model.badgeRegex, prompt: Text(verbatim: #"\((\d+)\)"#))
            LabeledContent("Also open in app") {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $model.extraHostsText)
                        .font(.body.monospaced())
                        .frame(height: 72)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("One host per line, for example whatsapp.com").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Menu bar icon", isOn: Binding(get: { model.menuBarIcon }, set: { model.setMenuBarIcon($0) }))
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Keep running in the menu bar when the window closes", isOn: $model.backgroundMode)
                    .disabled(!model.menuBarIcon)
                    .help(model.menuBarIcon ? "" : "Turn on the menu bar icon first")
                if !model.menuBarIcon {
                    Text("Turn on the menu bar icon first").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Web apps keep their data in a private web data store").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.columns)
    }
}
