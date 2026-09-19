import Foundation
import Testing
@testable import GunnAire_Ops

/// A recorded stall names the operations that overlapped it. The log is
/// written by the main actor and read by the stall callback after the fact,
/// so what matters is that the overlap test is right at the edges.
struct AppPerformanceOperationLogTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_789_757_748)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    @Test func anOperationRunningDuringTheStallIsNamed() {
        let clock = Clock()
        let log = AppPerformanceOperationLog(clock: { clock.now })
        log.begin("replica.capture")
        clock.advance(1)
        log.end()
        let stallStart = clock.now.addingTimeInterval(-0.8)
        #expect(log.names(overlapping: stallStart, end: clock.now) == ["replica.capture"])
    }

    @Test func anOperationThatEndedBeforeTheStallIsNotNamed() {
        let clock = Clock()
        let log = AppPerformanceOperationLog(clock: { clock.now })
        log.begin("replica.readSource")
        clock.advance(0.2)
        log.end()
        clock.advance(5)
        let stallStart = clock.now.addingTimeInterval(-1)
        #expect(log.names(overlapping: stallStart, end: clock.now).isEmpty)
    }

    @Test func anOperationStillOpenCountsAsRunningUntilNow() {
        let clock = Clock()
        let log = AppPerformanceOperationLog(clock: { clock.now })
        log.begin("replica.deliver")
        clock.advance(3)
        #expect(log.names(overlapping: clock.now.addingTimeInterval(-1), end: clock.now) == ["replica.deliver"])
    }

    @Test func sequentialStepsAreListedOnceEachOldestFirstAndTheRingStaysBounded() {
        let clock = Clock()
        let log = AppPerformanceOperationLog(capacity: 3, clock: { clock.now })
        for name in ["a", "b", "c", "d", "d"] {
            log.begin(name)
            clock.advance(0.1)
            log.end()
        }
        let names = log.names(overlapping: clock.now.addingTimeInterval(-10), end: clock.now)
        #expect(names == ["c", "d"])
    }
}
