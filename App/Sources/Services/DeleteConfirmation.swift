import Foundation

/// The second step before a data folder outside the data root goes to the Trash with its shortcut (re-review
/// Minor 1, final review M24): the delete sheet asks again, naming the folder.
struct DeleteConfirmation: Equatable {
    let title: String
    let message: String

    /// Nil unless `removeData` is on and `option` offers a folder outside the data root.
    init?(shortcutName: String, option: DataFolderDeletionOption, removeData: Bool) {
        guard removeData, case .available(folder: let folder, outsideDataRoot: true) = option else { return nil }
        title = "Also move “\(folder.lastPathComponent)” to the Trash?"
        message = "The data folder of “\(shortcutName)” is \(folder.path), outside ~/Library/Application Support/App Duplicator. Everything in it is moved to the Trash with the shortcut."
    }
}
