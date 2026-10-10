import XCTest
@testable import MacAppDuplicator

final class DeleteConfirmationTests: XCTestCase {
    func testAsksOnlyBeforeTrashingADataFolderOutsideTheDataRoot() throws {
        let outside = DataFolderDeletionOption.available(folder: URL(fileURLWithPath: "/Volumes/Work/Shared Data", isDirectory: true), outsideDataRoot: true)
        let inside = DataFolderDeletionOption.available(
            folder: URL(fileURLWithPath: "/Users/someone/Library/Application Support/App Duplicator/work", isDirectory: true), outsideDataRoot: false
        )

        XCTAssertNil(DeleteConfirmation(shortcutName: "Work", option: outside, removeData: false), "nothing to confirm when the folder stays")
        XCTAssertNil(DeleteConfirmation(shortcutName: "Work", option: inside, removeData: true), "a folder inside the data root needs no second step")
        XCTAssertNil(DeleteConfirmation(shortcutName: "Work", option: .unavailable(note: "No data folder exists."), removeData: true))

        let confirmation = try XCTUnwrap(DeleteConfirmation(shortcutName: "Work", option: outside, removeData: true))
        XCTAssertEqual(confirmation.title, "Also move “Shared Data” to the Trash?")
        XCTAssertEqual(
            confirmation.message,
            "The data folder of “Work” is /Volumes/Work/Shared Data, outside ~/Library/Application Support/App Duplicator. Everything in it is moved to the Trash with the shortcut."
        )
    }
}
