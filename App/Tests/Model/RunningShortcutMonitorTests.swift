import Foundation
import Synchronization
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// A process probe that returns canned results in call order and blocks gated calls until the test releases them.
final class GatedProbe: Sendable {
    private let results: [Set<String>]
    private let gates: [Int: DispatchSemaphore]
    private let callCount = Mutex(0)
    private let started = Mutex<Set<Int>>([])

    init(results: [Set<String>], gatedCalls: Set<Int>) {
        self.results = results
        self.gates = Dictionary(uniqueKeysWithValues: gatedCalls.map { ($0, DispatchSemaphore(value: 0)) })
    }

    /// Runs on the detached probe task, never on the main actor, so blocking on a gate is safe.
    func next() -> Set<String> {
        let call = callCount.withLock { count in
            count += 1
            return count
        }
        started.withLock { _ = $0.insert(call) }
        gates[call]?.wait()
        return results[min(call, results.count) - 1]
    }

    func hasStarted(call: Int) -> Bool { started.withLock { $0.contains(call) } }

    func release(call: Int) { gates[call]?.signal() }
}

final class RunningShortcutMonitorTests: XCTestCase {
    @MainActor
    func testStaleRefreshThatLandsLastIsDropped() async {
        let probe = GatedProbe(results: [["/stale/Old.app"], ["/fresh/New.app"]], gatedCalls: [1])
        let monitor = RunningShortcutMonitor(probe: { probe.next() })

        let stale = Task { await monitor.refresh() }
        await waitUntil { probe.hasStarted(call: 1) }
        await monitor.refresh()
        XCTAssertEqual(monitor.runningBundlePaths, ["/fresh/New.app"])

        probe.release(call: 1)
        await stale.value
        XCTAssertEqual(monitor.runningBundlePaths, ["/fresh/New.app"], "a stale refresh replaced a newer one")
        XCTAssertFalse(monitor.isRunning(bundleURL: URL(fileURLWithPath: "/stale/Old.app")))
    }

    @MainActor
    func testRunningIdentifiersComeFromTheInjectedProbeAndMatchCaseInsensitively() async {
        let monitor = RunningShortcutMonitor(probe: { [] }, identifierProbe: { ["com.mikekuta.appduplicator.chat-work"] })
        await monitor.refresh()

        XCTAssertTrue(monitor.isRunning(bundleURL: URL(fileURLWithPath: "/x/Chat Work.app"), bundleIdentifier: "com.mikekuta.AppDuplicator.Chat-Work"))
        XCTAssertFalse(monitor.isRunning(bundleURL: URL(fileURLWithPath: "/x/Other.app"), bundleIdentifier: "com.mikekuta.appduplicator.other"))
        XCTAssertFalse(monitor.isRunning(bundleURL: URL(fileURLWithPath: "/x/Chat Work.app")), "without an identifier only the path probe counts")
    }

    @MainActor
    func testLibraryUsesIdentifiersOnlyForWebApps() async throws {
        let (defaults, suite) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let web = makeWebConfig(name: "Chat Work")
        let monitor = RunningShortcutMonitor(probe: { [] }, identifierProbe: { [web.bundleIdentifier.lowercased()] })
        let library = ShortcutLibrary(settings: AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc"), monitor: monitor)
        await monitor.refresh()

        func record(_ config: ShortcutConfig) -> ShortcutRecord {
            ShortcutRecord(bundleURL: URL(fileURLWithPath: "/x/\(config.name).app"), config: config, engineVersion: ShortcutConfig.currentEngineVersion,
                           iconURL: nil, targetVersion: nil, targetExists: true, modifiedDate: .distantPast, provenance: .own)
        }
        var native = makeConfig(name: "Native Work")
        native.bundleIdentifier = web.bundleIdentifier
        XCTAssertTrue(library.isRunning(record(web)))
        XCTAssertFalse(library.isRunning(record(native)), "a native shortcut is only running when its launcher marker says so")
    }
}
