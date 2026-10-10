import AppKit
import DuplicatorCore
import SwiftUI
import UniformTypeIdentifiers

/// Phase 5 target step for "File or Folder": pick the item (the model sets `.file` or `.folder` from what was chosen)
/// and, optionally, the app that opens it.
struct FileTargetStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        Form {
            Section("Item") {
                LabeledContent("Opens") {
                    HStack {
                        Text(model.itemPath ?? "Nothing chosen")
                            .foregroundStyle(model.itemPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseItem)
                            .help("Choose the file or folder this shortcut opens")
                    }
                }
                if let error = model.itemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if model.itemPath != nil {
                    LabeledContent("Kind", value: model.kind == .folder ? "Folder" : "File")
                }
            }
            Section("Open with") {
                LabeledContent("App") {
                    HStack {
                        Text(model.openerAppPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Default app")
                        Button("Choose…", action: chooseOpener)
                            .help("Open the item with a specific app instead of its default app")
                        if model.openerAppPath != nil {
                            Button("Use Default") { model.selectOpener(nil) }
                                .help("Open the item with the app macOS picks for it")
                        }
                    }
                }
                if let error = model.openerError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.columns)
    }

    private func chooseItem() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the file or folder this shortcut opens."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectItem(url)
    }

    /// Starts in /Applications, but an app anywhere is accepted.
    private func chooseOpener() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Choose"
        panel.message = "Choose the app that opens the item."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectOpener(url)
    }
}
