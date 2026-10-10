@testable import WebShell
import XCTest

final class HiddenWindowRegistryTests: XCTestCase {
    private final class FakeWindow {}

    func testRememberedWindowsComeBackOnceInOrderThenTheRegistryIsEmpty() {
        let first = FakeWindow(), second = FakeWindow()
        var registry = HiddenWindowRegistry<FakeWindow>()
        XCTAssertTrue(registry.isEmpty)
        registry.remember([first, second])
        let taken = registry.takeAll()
        XCTAssertEqual(taken.count, 2)
        XCTAssertTrue(taken[0] === first && taken[1] === second)
        XCTAssertTrue(registry.isEmpty)
        XCTAssertTrue(registry.takeAll().isEmpty, "a second reveal has nothing left to show")
    }

    func testHidingTheSameWindowTwiceRemembersItOnce() {
        let window = FakeWindow()
        var registry = HiddenWindowRegistry<FakeWindow>()
        registry.remember([window])
        registry.remember([window])
        XCTAssertEqual(registry.takeAll().count, 1)
    }

    func testAWindowThatClosedWhileHiddenIsForgottenAndNotRetained() {
        let kept = FakeWindow()
        var registry = HiddenWindowRegistry<FakeWindow>()
        weak var closed: FakeWindow?
        do {
            let window = FakeWindow()
            closed = window
            registry.remember([window, kept])
            registry.forget(window)
        }
        XCTAssertNil(closed, "the registry must not keep a closed popup alive")
        let taken = registry.takeAll()
        XCTAssertEqual(taken.count, 1)
        XCTAssertTrue(taken[0] === kept)
    }

    func testForgettingAnUnknownWindowChangesNothing() {
        let known = FakeWindow()
        var registry = HiddenWindowRegistry<FakeWindow>()
        registry.remember([known])
        registry.forget(FakeWindow())
        XCTAssertEqual(registry.takeAll().count, 1)
    }
}
