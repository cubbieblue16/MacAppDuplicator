import Foundation

/// The helper runs with the shortcut's environment, so `MAD_SHORTCUT_BUNDLE` keeps the app's running indicator on and
/// New Window sees the shortcut's variables, except `HOME` and `CFFIXED_USER_HOME`: those keep the launcher's own values,
/// because the helper's log and `EraseOnQuitPolicy` must resolve the real home, never the data folder (spec §4.3, §4.6).
/// The shortcut's two values travel under the `MAD_HELPER_TARGET_*` keys and come back for New Window.
public enum HelperEnvironment {
    public static let targetHomeKey = "MAD_HELPER_TARGET_HOME"
    public static let targetFixedHomeKey = "MAD_HELPER_TARGET_CFFIXED_USER_HOME"

    /// Each home variable and the key that carries the shortcut's value inside the helper.
    static let stashedKeys: [(key: String, stash: String)] = [("HOME", targetHomeKey), ("CFFIXED_USER_HOME", targetFixedHomeKey)]

    /// `shortcut` with `HOME` and `CFFIXED_USER_HOME` taken from `base` (removed where `base` has none) and the
    /// shortcut's own values stored under the stash keys (removed where the shortcut has none).
    public static func helperEnvironment(shortcut: [String: String], base: [String: String]) -> [String: String] {
        var environment = shortcut
        for (key, stash) in stashedKeys {
            environment[stash] = shortcut[key]
            environment[key] = base[key]
        }
        return environment
    }

    /// The shortcut environment again: both home variables restored from the stash keys, the stash keys removed.
    public static func targetEnvironment(helper: [String: String]) -> [String: String] {
        var environment = helper
        for (key, stash) in stashedKeys {
            environment[key] = helper[stash]
            environment[stash] = nil
        }
        return environment
    }
}
