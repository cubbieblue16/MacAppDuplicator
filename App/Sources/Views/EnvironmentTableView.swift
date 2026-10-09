import DuplicatorCore
import SwiftUI

/// Name/value editor. Values whose names match `SecretMasking` are hidden until the row's eye toggle is on (spec §7).
struct EnvironmentTableView: View {
    @Binding var environment: [String: String]
    @State private var revealed: Set<String> = []
    @State private var newName = ""
    @State private var newValue = ""

    private var names: [String] { environment.keys.sorted() }

    var body: some View {
        LabeledContent("Environment") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(names, id: \.self) { name in
                    HStack {
                        Text(name).font(.body.monospaced()).frame(width: 160, alignment: .leading)
                        if SecretMasking.isSecretKey(name) && !revealed.contains(name) {
                            Text(SecretMasking.maskedValue).foregroundStyle(.secondary)
                        } else {
                            TextField("Value", text: Binding(
                                get: { environment[name] ?? "" },
                                set: { environment[name] = $0 }
                            )).font(.body.monospaced())
                        }
                        if SecretMasking.isSecretKey(name) {
                            Toggle(isOn: Binding(
                                get: { revealed.contains(name) },
                                set: { if $0 { revealed.insert(name) } else { revealed.remove(name) } }
                            )) { Image(systemName: revealed.contains(name) ? "eye.slash" : "eye") }
                            .toggleStyle(.button)
                            .help(revealed.contains(name) ? "Hide value" : "Reveal value")
                        }
                        Button { environment.removeValue(forKey: name) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove \(name)")
                    }
                }
                HStack {
                    TextField("Name", text: $newName).font(.body.monospaced()).frame(width: 160)
                    TextField("Value", text: $newValue).font(.body.monospaced())
                    Button { add() } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Add variable")
                }
            }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        environment[name] = newValue
        newName = ""
        newValue = ""
    }
}
