/// Titles of the helper's status item menu (spec §4.6), worded like WebShell's `StatusItemText`.
public enum HelperMenuText {
    public static let newWindow = "New Window"

    public static func show(name: String) -> String {
        "Show \(name)"
    }

    public static func quit(name: String) -> String {
        "Quit \(name)"
    }
}
