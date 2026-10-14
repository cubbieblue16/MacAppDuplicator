import CompatProfiles
import DuplicatorCore

/// Read-only text for a compatibility profile (spec §8), shared by the wizard Review step, the editor's Profile
/// section and Diagnostics. Argument and environment values pass through `SecretMasking` by default, so a profile's
/// secrets never reach a copied Diagnostics report. The wizard Review step passes `maskProfileValues: false` and shows
/// `profileValuesCaption`: a profile is a remote document, and masking a key that merely looks secret
/// (`GIT_CONFIG_KEY_0`) would hide what a malicious profile does.
enum ProfileSummary {
    /// One label/value line of a profile summary.
    struct Row: Equatable, Identifiable, Sendable {
        var label: String
        var value: String
        var id: String { label }
    }

    /// Shown in place of a remote profile's New Window command that fails `NewWindowCommandBuilder.profileValidationMessage`.
    static let ignoredNewWindowNote = "Profile New Window command ignored (not allowed)"

    /// One-line caption shown next to profile-sourced values that are not masked.
    static let profileValuesCaption = "Values from the compatibility profile are shown in full."

    static func statusLabel(_ status: ProfileStatus) -> String {
        switch status {
        case .verified: "Verified"
        case .partial: "Partial"
        case .unsupported: "Unsupported"
        }
    }

    static func familyName(_ family: AppFamily) -> String {
        switch family {
        case .todesktop: "ToDesktop"
        case .electron: "Electron"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .eclipse: "Eclipse"
        case .native: "Native"
        }
    }

    /// `Name`, `Status`, `Family` (when the profile names one), `Arguments` and `Environment` (masked unless `maskProfileValues` is false, `None`
    /// when empty), `New Window` (the template, masked the same way, when the profile has one), `Notes` (when the profile has any) and
    /// `Family note` (see `familyNote`). Empty without a profile.
    static func rows(for profile: AppProfile?, detectedFamily: AppFamily?, maskProfileValues: Bool = true) -> [Row] {
        guard let profile else { return [] }
        var rows = [Row(label: "Name", value: profile.name), Row(label: "Status", value: statusLabel(profile.status))]
        if let family = profile.family {
            rows.append(Row(label: "Family", value: familyName(family)))
        }
        let arguments = maskProfileValues ? SecretMasking.maskArguments(profile.args) : profile.args
        rows.append(Row(label: "Arguments", value: arguments.isEmpty ? "None" : arguments.joined(separator: " ")))
        let environment = maskProfileValues ? SecretMasking.mask(profile.env) : profile.env
        rows.append(Row(label: "Environment",
                        value: environment.isEmpty ? "None" : environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: " ")))
        if let template = profile.newWindowCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty {
            if NewWindowCommandBuilder.profileValidationMessage(for: template) != nil {
                // The wizard does not copy this template (WizardModel.selectTarget); say so instead of listing it as a default.
                rows.append(Row(label: "New Window", value: ignoredNewWindowNote))
            } else {
                let tokens = template.split(whereSeparator: \.isWhitespace).map(String.init)
                rows.append(Row(label: "New Window", value: (maskProfileValues ? SecretMasking.maskArguments(tokens) : tokens).joined(separator: " ")))
            }
        }
        if let notes = profile.notes, !notes.isEmpty {
            rows.append(Row(label: "Notes", value: notes))
        }
        if let note = familyNote(profile: profile, detected: detectedFamily) {
            rows.append(Row(label: "Family note", value: note))
        }
        return rows
    }

    /// The Diagnostics profile match: `<bundle id> · <status> · updated <date> · <bundled|cached>` when the catalog has
    /// a profile for the bundle id, `No profile for <bundle id> (profiles updated <date>, <source>)` when it does not,
    /// and `No profiles loaded.` when no catalog is loaded.
    static func matchLine(bundleIdentifier: String, catalog: ProfileCatalog) -> String {
        guard !catalog.updated.isEmpty else { return "No profiles loaded." }
        guard let profile = catalog.profile(forBundleIdentifier: bundleIdentifier) else {
            return "No profile for \(bundleIdentifier) (profiles updated \(catalog.updated), \(catalog.source.rawValue))"
        }
        return "\(bundleIdentifier) · \(statusLabel(profile.status)) · updated \(catalog.updated) · \(catalog.source.rawValue)"
    }

    /// Launch settings always follow the family AppInspector detects; a profile's `family` is informational. Returns a
    /// note when both are known and differ, nil otherwise.
    static func familyNote(profile: AppProfile?, detected: AppFamily?) -> String? {
        guard let listed = profile?.family, let detected, listed != detected else { return nil }
        return "The profile lists family \(familyName(listed)) but App Duplicator detected \(familyName(detected)); launch settings follow the detected family."
    }
}
