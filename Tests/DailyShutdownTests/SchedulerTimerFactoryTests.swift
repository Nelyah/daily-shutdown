import XCTest
@testable import DailyShutdown

// MARK: - Mock Timer Factory
final class MockTimerFactory: TimerFactory {
    struct Scheduled { let interval: TimeInterval; let handler: () -> Void }
    private(set) var singles: [Scheduled] = []
    func scheduleSingle(after interval: TimeInterval, queue: DispatchQueue, handler: @escaping () -> Void) -> CancellableTimer {
        let scheduled = Scheduled(interval: interval, handler: handler)
        singles.append(scheduled)
        return DummyToken(cancelCallback: {})
    }
    private final class DummyToken: CancellableTimer { let cancelCallback: () -> Void; init(cancelCallback: @escaping () -> Void) { self.cancelCallback = cancelCallback } ; func cancel() { cancelCallback() } }
}

final class SchedulerTimerFactoryTests: XCTestCase {
    func testSchedulesExpectedWarningIntervals() throws {
        let factory = MockTimerFactory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = Scheduler(queue: DispatchQueue(label: "test.queue"), timerFactory: factory, clock: FixedClock(fixed: now))
        let shutdown = now.addingTimeInterval(3600)
        let offsets = [900, 300, 60]
        scheduler.schedule(shutdownDate: shutdown, warningDate: shutdown.addingTimeInterval(-900), warningOffsets: offsets)
        let intervals = factory.singles.map { $0.interval }.sorted(by: >)
        XCTAssertEqual(intervals.count, 4, "Expected 1 final + 3 warning timers")
        // Intervals captured are remaining seconds until each event fires, not raw offsets.
        // For finalInterval = 3600, warning offsets produce remaining intervals: 3600 (final), 2700 (15m), 3300 (5m), 3540 (1m).
        let expectedRemaining: Set<Int> = [3600, 2700, 3300, 3540]
        let capturedRounded = Set(intervals.map { Int(round($0)) })
        XCTAssertEqual(capturedRounded, expectedRemaining)
        // Ensure uniqueness and all positive.
        XCTAssertTrue(capturedRounded.allSatisfy { $0 > 0 })
    }

    func testSkipsPastWarningOffsets() throws {
        let factory = MockTimerFactory()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let scheduler = Scheduler(queue: DispatchQueue(label: "test.queue"), timerFactory: factory, clock: FixedClock(fixed: now))
        let shutdown = now.addingTimeInterval(240)
        let offsets = [900, 300, 60]
        scheduler.schedule(shutdownDate: shutdown, warningDate: nil, warningOffsets: offsets)
        let intervals = factory.singles.map { Int(round($0.interval)) }.sorted(by: >)
        // Remaining intervals expected: 240 (final), 180 (warning at 60s before)
        XCTAssertEqual(intervals, [240, 180])
    }

    func testCancelClearsTimers() throws {
        let factory = MockTimerFactory()
        let now = Date(timeIntervalSince1970: 3_000_000)
        let scheduler = Scheduler(queue: DispatchQueue(label: "test.queue"), timerFactory: factory, clock: FixedClock(fixed: now))
        scheduler.schedule(shutdownDate: now.addingTimeInterval(100), warningDate: nil, warningOffsets: [30,10])
        XCTAssertFalse(factory.singles.isEmpty)
        scheduler.cancel()
        scheduler.cancel() // should remain idempotent / no crash
    }
}
