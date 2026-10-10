import Foundation

/// The second step before something irreversible goes with a shortcut: a data folder outside the data root (re-review
/// Minor 1, final review M24) or a web app's web data (Phase 4). The delete sheet asks again, naming what goes.
struct DeleteConfirmation: Equatable {
    let title: String
    let message: String

    private init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    /// Nil unless `removeData` is on and `option` offers a folder outside the data root.
    init?(shortcutName: String, option: DataFolderDeletionOption, removeData: Bool) {
        guard removeData, case .available(folder: let folder, outsideDataRoot: true) = option else { return nil }
        self.init(
            title: "Also move “\(folder.lastPathComponent)” to the Trash?",
            message: "The data folder of “\(shortcutName)” is \(folder.path), outside ~/Library/Application Support/App Duplicator. Everything in it is moved to the Trash with the shortcut."
        )
    }

    /// Asked for every web app on Delete; the default answer keeps the web data.
    static func webData(shortcutName: String) -> DeleteConfirmation {
        DeleteConfirmation(
            title: "Also remove web data (logins, cookies, cache)?",
            message: "Removing it signs “\(shortcutName)” out of every site and deletes its cookies, cache and local storage from this Mac. Keeping it leaves them in place, so putting the shortcut back from the Trash brings the logins back."
        )
    }
}

/// What the delete sheet asks `AppState.delete` to do besides trashing the bundle.
struct DeleteRequest: Equatable {
    var removeDataFolder: Bool
    var removeWebData: Bool

    /// Trash the shortcut and keep both the data folder and the web data.
    static let keepAll = DeleteRequest(removeDataFolder: false, removeWebData: false)
}
