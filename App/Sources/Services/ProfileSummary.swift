import CompatProfiles
import DuplicatorCore

/// Read-only text for a compatibility profile (spec §8), shared by the wizard Review step, the editor's Profile
/// section and Diagnostics. Argument and environment values pass through `SecretMasking`, so a profile's secrets are
/// never shown.
enum ProfileSummary {
    /// One label/value line of a profile summary.
    struct Row: Equatable, Identifiable, Sendable {
        var label: String
        var value: String
        var id: String { label }
    }

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

    /// `Name`, `Status`, `Family` (when the profile names one), `Arguments` and `Environment` (masked, `None` when
    /// empty), `New Window` (the masked template, when the profile has one), `Notes` (when the profile has any) and
    /// `Family note` (see `familyNote`). Empty without a profile.
    static func rows(for profile: AppProfile?, detectedFamily: AppFamily?) -> [Row] {
        guard let profile else { return [] }
        var rows = [Row(label: "Name", value: profile.name), Row(label: "Status", value: statusLabel(profile.status))]
        if let family = profile.family {
            rows.append(Row(label: "Family", value: familyName(family)))
        }
        let arguments = SecretMasking.maskArguments(profile.args)
        rows.append(Row(label: "Arguments", value: arguments.isEmpty ? "None" : arguments.joined(separator: " ")))
        let environment = SecretMasking.mask(profile.env)
        rows.append(Row(label: "Environment",
                        value: environment.isEmpty ? "None" : environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: " ")))
        if let template = profile.newWindowCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty {
            let tokens = template.split(whereSeparator: \.isWhitespace).map(String.init)
            rows.append(Row(label: "New Window", value: SecretMasking.maskArguments(tokens).joined(separator: " ")))
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
