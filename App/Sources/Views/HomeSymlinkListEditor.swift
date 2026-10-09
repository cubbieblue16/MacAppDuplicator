import SwiftUI

/// Editable list of HOME-relative paths. Entries are trimmed; blank entries are dropped on commit.
struct HomeSymlinkListEditor: View {
    @Binding var entries: [String]
    @State private var selection: Int?
    @State private var newEntry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, _ in
                    TextField("Path", text: Binding(
                        get: { entries.indices.contains(index) ? entries[index] : "" },
                        set: { entries[index] = $0 }
                    ))
                    .font(.body.monospaced())
                    .tag(index)
                }
            }
            .frame(minHeight: 140)
            .onSubmit { commit() }
            HStack {
                TextField("Add path, e.g. Library/Keychains", text: $newEntry)
                    .font(.body.monospaced())
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus") }
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    if let selection, entries.indices.contains(selection) {
                        entries.remove(at: selection)
                        self.selection = nil
                    }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
            }
        }
    }

    private func add() {
        let trimmed = newEntry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !entries.contains(trimmed) else { return }
        entries.append(trimmed)
        newEntry = ""
    }

    private func commit() {
        entries = entries.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
