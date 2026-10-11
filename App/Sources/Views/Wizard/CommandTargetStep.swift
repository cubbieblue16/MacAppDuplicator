import AppKit
import DuplicatorCore
import SwiftUI

/// Phase 5 target step for "Command": the program, its arguments (one per line), the working directory and where it runs.
struct CommandTargetStep: View {
    @Bindable var model: WizardModel
    @State private var argumentsText = ""

    var body: some View {
        Form {
            Section("Program") {
                LabeledContent("Executable") {
                    HStack {
                        TextField("Executable", text: $model.cliExecutable, prompt: Text("/usr/local/bin/tool"))
                            .labelsHidden()
                            .help("The full path of the program or script to run")
                        Button("Choose…", action: chooseExecutable)
                            .help("Choose the program or script to run")
                    }
                }
                if !model.cliExecutable.trimmingCharacters(in: .whitespaces).isEmpty, let error = model.cliExecutableError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Arguments") {
                    TextEditor(text: $argumentsText)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 72)
                        .help("One argument per line. Spaces and quotes are passed exactly as typed; empty lines are ignored.")
                }
                LabeledContent("Working directory") {
                    TextField("Working directory", text: workingDirectory, prompt: Text("Default"))
                        .labelsHidden()
                        .help("The folder the command starts in; ~ means your home folder")
                }
            }
            Section("Run in") {
                Picker("Terminal", selection: $model.terminal) {
                    ForEach(WizardModel.terminalChoices, id: \.self) { choice in
                        Text(WizardModel.terminalLabel(choice)).tag(choice)
                    }
                }
                .help("Terminal and iTerm2 are driven through AppleScript, so macOS asks once for permission. No terminal runs the command in the background.")
            }
        }
        .formStyle(.columns)
        .onAppear { argumentsText = model.cliArguments.joined(separator: "\n") }
        .onChange(of: argumentsText) { _, text in model.cliArguments = WizardModel.parseArguments(text) }
    }

    private var workingDirectory: Binding<String> {
        Binding(get: { model.cliWorkingDirectory ?? "" }, set: { model.cliWorkingDirectory = $0.isEmpty ? nil : $0 })
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the program or script to run."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.cliExecutable = url.path
    }
}

/// Phase 5 Data step for a command: only the own-HOME toggle (a command has no target app data to separate).
struct CommandDataStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        Form {
            Section("Data") {
                Toggle("Give this command its own HOME", isOn: $model.cliHomeOverride)
                    .help("Runs the command with HOME set to a private folder, so its dotfiles and settings stay apart from yours")
                if model.cliHomeOverride {
                    Text("HOME will be \(model.commandHomePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.columns)
    }
}
