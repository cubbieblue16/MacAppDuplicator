import Foundation
import Synchronization
import XCTest
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
}
