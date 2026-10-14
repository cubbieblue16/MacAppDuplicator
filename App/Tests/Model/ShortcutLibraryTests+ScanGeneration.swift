import Foundation
import Synchronization
import XCTest
@testable import MacAppDuplicator

/// Wraps the real scanner. Every call scans for real; each call listed in `gatedCalls` then records that it has
/// finished scanning and blocks until `release(call:)`, so a test can make an older scan land after a newer one
/// (final review M7). The semaphore wait sits inside the synchronous `scan`, never directly in async code.
final class GatedScanner: ShortcutScanning {
    private let gates: [Int: DispatchSemaphore]
    private let callCount = Mutex(0)
    private let finishedCalls = Mutex<Set<Int>>([])

    init(gatedCalls: Set<Int>) {
        gates = Dictionary(uniqueKeysWithValues: gatedCalls.map { ($0, DispatchSemaphore(value: 0)) })
    }

    func scan(folders: [URL], trust: ScanTrust) -> ScanResult {
        let call = callCount.withLock { count in
            count += 1
            return count
        }
        let result = LibraryScanner().scan(folders: folders, trust: trust)
        finishedCalls.withLock { _ = $0.insert(call) }
        gates[call]?.wait()
        return result
    }

    func hasFinishedScanning(call: Int) -> Bool { finishedCalls.withLock { $0.contains(call) } }
    func release(call: Int) { gates[call]?.signal() }
}

extension ShortcutLibraryTests {
    @MainActor
    func testStaleScanThatLandsLastIsDropped() async throws {
        let root = try makeAppTemporaryDirectory()
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.outputFolder = root
        let scanner = GatedScanner(gatedCalls: [1])
        let library = ShortcutLibrary(settings: settings, scanner: scanner, monitor: RunningShortcutMonitor(probe: { [] }))

        // Scan 1 sees the empty folder, then blocks before its result can land.
        let stale = Task { await library.rescan() }
        await waitUntil { scanner.hasFinishedScanning(call: 1) }
        XCTAssertTrue(library.isScanning)

        // Scan 2 sees the new bundle and lands first.
        let bundle = try writeShortcutBundle(named: "Fresh.app", in: root, config: makeConfig(name: "Fresh"))
        await library.rescan()
        XCTAssertNotNil(library.record(for: bundle))
        XCTAssertFalse(library.isScanning)

        // Scan 1's empty result lands last and must be dropped.
        scanner.release(call: 1)
        await stale.value
        XCTAssertNotNil(library.record(for: bundle), "a stale scan result replaced a newer one")
        XCTAssertEqual(library.records.count, 1)
        XCTAssertFalse(library.isScanning)
    }

    @MainActor
    func testOnlyTheNewestScanClearsIsScanning() async throws {
        let root = try makeAppTemporaryDirectory()
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.outputFolder = root
        let scanner = GatedScanner(gatedCalls: [1, 2])
        let library = ShortcutLibrary(settings: settings, scanner: scanner, monitor: RunningShortcutMonitor(probe: { [] }))

        let stale = Task { await library.rescan() }
        await waitUntil { scanner.hasFinishedScanning(call: 1) }
        let bundle = try writeShortcutBundle(named: "Fresh.app", in: root, config: makeConfig(name: "Fresh"))
        let newest = Task { await library.rescan() }
        await waitUntil { scanner.hasFinishedScanning(call: 2) }

        // The stale scan lands while the newest is still running: it must neither publish nor clear isScanning.
        scanner.release(call: 1)
        await stale.value
        XCTAssertTrue(library.isScanning, "a stale scan cleared isScanning while a newer scan was running")
        XCTAssertNil(library.record(for: bundle))
        XCTAssertTrue(library.records.isEmpty)

        scanner.release(call: 2)
        await newest.value
        XCTAssertFalse(library.isScanning)
        XCTAssertNotNil(library.record(for: bundle))
    }
}
