import SwiftUI

struct NewShortcutWizard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model: WizardModel

    init() {
        _model = State(initialValue: WizardModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Shortcut").font(.headline)
                Spacer()
                Text("Step \(model.step.rawValue + 1) of \(WizardModel.Step.allCases.count)").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                switch model.step {
                case .kind: KindStep(model: model)
                case .target: TargetStep(model: model)
                case .identity: IdentityStep(model: model)
                case .data: DataStep(model: model)
                case .review: ReviewStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.step != .kind {
                    Button("Back") { model.back() }.disabled(model.isCreating)
                }
                if model.isLastStep {
                    Button {
                        create()
                    } label: {
                        if model.isCreating { ProgressView().controlSize(.small) } else { Text("Create") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdvance)
                } else {
                    Button("Next") { model.next() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAdvance)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .onAppear {
            if let prefill = appState.wizardPrefillTarget {
                model = WizardModel(prefillTarget: prefill)
                appState.wizardPrefillTarget = nil
            }
        }
    }

    private func create() {
        model.isCreating = true
        Task {
            let url = await appState.create(config: model.makeConfig())
            model.isCreating = false
            if url != nil { dismiss() }
        }
    }
}
