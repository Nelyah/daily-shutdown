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
        let scheduler = Scheduler(queue: DispatchQueue(label: "test.queue"), timerFactory: factory)
        let now = Date()
        let shutdown = now.addingTimeInterval(3600)
        let offsets = [900, 300, 60]
        scheduler.schedule(shutdownDate: shutdown, warningDate: shutdown.addingTimeInterval(-900), warningOffsets: offsets)
        let intervals = factory.singles.map { $0.interval }
        XCTAssertEqual(intervals.count, 4, "Expected 1 final + 3 warning timers")
        // Helper to check approximately present
        func containsApprox(_ target: TimeInterval, tolerance: TimeInterval = 1.0) -> Bool {
            intervals.contains { abs($0 - target) <= tolerance }
        }
        XCTAssertTrue(containsApprox(3600))
        XCTAssertTrue(containsApprox(900))
        XCTAssertTrue(containsApprox(300))
        XCTAssertTrue(containsApprox(60))
        // Ensure only one approx 900 occurrence
        let approx900Count = intervals.filter { abs($0 - 900) <= 1.0 }.count
        XCTAssertEqual(approx900Count, 1)
    }

    func testSkipsPastWarningOffsets() throws {
        let factory = MockTimerFactory()
        let scheduler = Scheduler(queue: DispatchQueue(label: "test.queue"), timerFactory: factory)
        let now = Date()
        let shutdown = now.addingTimeInterval(240)
        let offsets = [900, 300, 60]
        scheduler.schedule(shutdownDate: shutdown, warningDate: nil, warningOffsets: offsets)
        let intervals = factory.singles.map { $0.interval }
        func containsApprox(_ target: TimeInterval, tol: TimeInterval = 1.0) -> Bool { intervals.contains { abs($0 - target) <= tol } }
        XCTAssertTrue(containsApprox(240)) // final
        XCTAssertTrue(containsApprox(60))  // only viable warning
        XCTAssertFalse(containsApprox(300))
        XCTAssertFalse(containsApprox(900))
    }

    func testCancelClearsTimers() throws {
        let factory = MockTimerFactory()
        let scheduler = Scheduler(queue: DispatchQueue(label: "test.queue"), timerFactory: factory)
        let now = Date()
        scheduler.schedule(shutdownDate: now.addingTimeInterval(100), warningDate: nil, warningOffsets: [30,10])
        XCTAssertFalse(factory.singles.isEmpty)
        scheduler.cancel()
        scheduler.cancel() // should remain idempotent / no crash
    }
}
