import SwiftUI

/// Editable list of names linked from the real home into a separate HOME (spec §4.3). Every entry that reaches
/// `entries` passes `HomeSymlinkEntry.problem(with:existing:)`; a refused add or edit shows an inline message and leaves
/// the stored list unchanged (an edited row that is still invalid reverts on Return).
struct HomeSymlinkListEditor: View {
    @Binding var entries: [String]
    @State private var rows: [Row] = []
    /// The list as this editor last wrote or loaded it, so an outside change (Reset to Default) can be told apart.
    @State private var syncedEntries: [String] = []
    @State private var selection: Row.ID?
    @State private var newEntry = ""
    @State private var message: String?

    /// Rows keep a stable identity, so removing one never shifts the selection or a field's editing state to another.
    /// `rows[i]` always corresponds to `entries[i]`.
    private struct Row: Identifiable {
        let id = UUID()
        var name: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(rows) { row in
                    TextField("Name", text: binding(for: row.id))
                        .font(.body.monospaced())
                        .onSubmit { revertInvalidEdit(row.id) }
                        .tag(row.id)
                }
            }
            .frame(minHeight: 140)
            HStack {
                TextField("Add an entry, e.g. .aws", text: $newEntry)
                    .font(.body.monospaced())
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus") }
                    .disabled(HomeSymlinkEntry.normalized(newEntry).isEmpty)
                Button(action: removeSelected) { Image(systemName: "minus") }
                    .disabled(selection == nil)
            }
            if let message {
                Label(message, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: load)
        .onChange(of: entries) {
            if entries != syncedEntries { load() }
        }
    }

    private func load() {
        syncedEntries = entries
        rows = entries.map { Row(name: $0) }
        selection = nil
        message = nil
    }

    private func write(_ updated: [String]) {
        syncedEntries = updated
        entries = updated
    }

    /// Bounds-checked: a row that no longer exists reads as empty and ignores writes.
    private func binding(for id: Row.ID) -> Binding<String> {
        Binding(
            get: { rows.first { $0.id == id }?.name ?? "" },
            set: { newValue in
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
                rows[index].name = newValue
                guard entries.indices.contains(index) else { return }
                var others = entries
                others.remove(at: index)
                if let problem = HomeSymlinkEntry.problem(with: newValue, existing: others) {
                    message = problem
                    return
                }
                message = nil
                var updated = entries
                updated[index] = HomeSymlinkEntry.normalized(newValue)
                write(updated)
            }
        )
    }

    private func revertInvalidEdit(_ id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }), entries.indices.contains(index) else { return }
        if rows[index].name != entries[index] {
            rows[index].name = entries[index]
            message = nil
        }
    }

    private func add() {
        if let problem = HomeSymlinkEntry.problem(with: newEntry, existing: entries) {
            message = problem
            return
        }
        let name = HomeSymlinkEntry.normalized(newEntry)
        rows.append(Row(name: name))
        write(entries + [name])
        newEntry = ""
        message = nil
    }

    private func removeSelected() {
        guard let selection, let index = rows.firstIndex(where: { $0.id == selection }) else { return }
        rows.remove(at: index)
        var updated = entries
        if updated.indices.contains(index) { updated.remove(at: index) }
        write(updated)
        self.selection = nil
        message = nil
    }
}
