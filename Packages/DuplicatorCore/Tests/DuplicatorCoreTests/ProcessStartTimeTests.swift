import Darwin
import XCTest
@testable import DuplicatorCore

final class ProcessStartTimeTests: XCTestCase {
    func testTheCurrentProcessHasAStableStartTimeInThePast() throws {
        let first = try XCTUnwrap(ProcessStartTime.of(getpid()))
        let second = try XCTUnwrap(ProcessStartTime.of(getpid()))
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first.seconds, 1_600_000_000)
        XCTAssertLessThanOrEqual(first.seconds, UInt64(Date().timeIntervalSince1970))
        XCTAssertLessThan(first.microseconds, 1_000_000)
    }

    func testAMissingProcessHasNoStartTime() {
        XCTAssertNil(ProcessStartTime.of(Int32.max))
        XCTAssertEqual(ProcessStartTime(seconds: 1, microseconds: 2).compare(toLiveProcess: Int32.max), .gone)
    }

    func testCompareTellsTheSameProcessFromAReusedPid() throws {
        let own = try XCTUnwrap(ProcessStartTime.of(getpid()))
        XCTAssertEqual(own.compare(toLiveProcess: getpid()), .same)
        let otherMicroseconds = ProcessStartTime(seconds: own.seconds, microseconds: (own.microseconds + 1) % 1_000_000)
        XCTAssertEqual(otherMicroseconds.compare(toLiveProcess: getpid()), .different)
        let otherSeconds = ProcessStartTime(seconds: own.seconds + 1, microseconds: own.microseconds)
        XCTAssertEqual(otherSeconds.compare(toLiveProcess: getpid()), .different)
    }
}
