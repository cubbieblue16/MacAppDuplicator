import CompatProfiles
import SwiftUI

/// Preset tiles for the web target step: name over host, same Button-based tile as `InstalledAppsGrid` (a VoiceOver
/// button, Space from keyboard focus, Return handled explicitly because macOS gives it to the default button).
struct WebAppPresetGrid: View {
    let presets: [WebAppPreset]
    let selection: WebAppPreset?
    let onSelect: (WebAppPreset) -> Void

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                    let host = WizardModel.presetHost(preset)
                    Button {
                        onSelect(preset)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "globe").font(.title2).frame(height: 28)
                            Text(preset.name).font(.callout).lineLimit(1)
                            Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(width: 132, height: 72)
                        .padding(6)
                        .background(selection == preset ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onKeyPress(.return) {
                        onSelect(preset)
                        return .handled
                    }
                    .accessibilityLabel("\(preset.name), \(host)")
                    .accessibilityAddTraits(selection == preset ? [.isButton, .isSelected] : [.isButton])
                }
            }
            .padding(4)
        }
    }
}

/// The target step for a web app: presets (name and host) and the `Website URL` field with inline validation.
struct WebTargetStep: View {
    @Bindable var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a website").font(.title3)
            if !model.webAppPresets.isEmpty {
                WebAppPresetGrid(presets: model.webAppPresets, selection: model.highlightedPreset) { model.applyPreset($0) }
                    .frame(minHeight: 120)
            }
            TextField("Website URL", text: $model.webURL, prompt: Text(verbatim: "https://example.com"))
                .textFieldStyle(.roundedBorder)
            if let error = model.webURLError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
            }
            Spacer(minLength: 0)
        }
    }
}
