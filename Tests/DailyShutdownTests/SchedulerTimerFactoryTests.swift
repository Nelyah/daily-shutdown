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
        let intervals = factory.singles.map { Int(round($0.interval)) }.sorted(by: >)
        XCTAssertTrue(intervals.contains(3600))
        XCTAssertTrue(intervals.contains(900))
        XCTAssertTrue(intervals.contains(300))
        XCTAssertTrue(intervals.contains(60))
        XCTAssertEqual(intervals.filter { $0 == 900 }.count, 1)
    }

    func testSkipsPastWarningOffsets() throws {
        let factory = MockTimerFactory()
        let scheduler = Scheduler(queue: DispatchQueue(label: "test.queue"), timerFactory: factory)
        let now = Date()
        let shutdown = now.addingTimeInterval(240)
        let offsets = [900, 300, 60]
        scheduler.schedule(shutdownDate: shutdown, warningDate: nil, warningOffsets: offsets)
        let intervals = factory.singles.map { Int(round($0.interval)) }
        XCTAssertTrue(intervals.contains(240))
        XCTAssertTrue(intervals.contains(60))
        XCTAssertFalse(intervals.contains(300))
        XCTAssertFalse(intervals.contains(900))
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
