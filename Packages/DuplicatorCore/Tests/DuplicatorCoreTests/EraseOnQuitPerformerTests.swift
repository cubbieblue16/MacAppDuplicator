import Darwin
import XCTest
@testable import DuplicatorCore

final class EraseOnQuitPerformerTests: XCTestCase {
    func testRemovesEveryChildIncludingHiddenOnesAndKeepsTheFolder() throws {
        let data = try makeTemporaryDirectory().appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data.appending(path: "Sub/Deeper", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: data.appending(path: "a.txt", directoryHint: .notDirectory))
        try Data("h".utf8).write(to: data.appending(path: ".hidden", directoryHint: .notDirectory))
        try Data("d".utf8).write(to: data.appending(path: "Sub/Deeper/d.txt", directoryHint: .notDirectory))

        let outcome = EraseOnQuitPerformer.erase(at: data)

        XCTAssertEqual(outcome, EraseOnQuitOutcome(removed: 3, failures: []))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: data.path), [])
    }

    func testSymbolicLinksAtAnyDepthAreRemovedWithoutTouchingTheirTargets() throws {
        let sandbox = try makeTemporaryDirectory()
        let outside = sandbox.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = outside.appending(path: "keep.txt", directoryHint: .notDirectory)
        try Data("keep".utf8).write(to: kept)
        let data = sandbox.appending(path: "Data", directoryHint: .isDirectory)
        let nested = data.appending(path: "Library/Preferences", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: data.appending(path: "Documents", directoryHint: .notDirectory), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: nested.appending(path: "Shared", directoryHint: .notDirectory), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: data.appending(path: "keep-link.txt", directoryHint: .notDirectory), withDestinationURL: kept)

        let outcome = EraseOnQuitPerformer.erase(at: data)

        XCTAssertEqual(outcome, EraseOnQuitOutcome(removed: 3, failures: []))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: data.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["keep.txt"])
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "keep")
    }

    func testAChildThatCannotBeRemovedIsReportedAndTheRestAreStillRemoved() throws {
        let data = try makeTemporaryDirectory().appending(path: "Data", directoryHint: .isDirectory)
        let locked = data.appending(path: "Locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appending(path: "inside.txt", directoryHint: .notDirectory))
        try Data("a".utf8).write(to: data.appending(path: "a.txt", directoryHint: .notDirectory))
        XCTAssertEqual(chmod(locked.path, 0o500), 0)
        defer { XCTAssertEqual(chmod(locked.path, 0o700), 0) }

        let outcome = EraseOnQuitPerformer.erase(at: data)

        XCTAssertEqual(outcome, EraseOnQuitOutcome(removed: 1, failures: ["Locked"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: data.path), ["Locked"])
    }
}
