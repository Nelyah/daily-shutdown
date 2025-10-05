import XCTest
@testable import DailyShutdown

/// Tests covering wake-from-sleep stale shutdown guard: we only shut down if now is the same
/// calendar day as the originally scheduled shutdown. If the machine wakes on a later day
/// past the scheduled time, the shutdown is skipped and a new cycle is created.
final class ShutdownControllerStaleWakeTests: XCTestCase {
    final class FixedClock: Clock { var nowValue: Date; init(now: Date) { self.nowValue = now }; func now() -> Date { nowValue } }
    final class TestActions: SystemActions { var shutdownCalls = 0; func shutdown() { shutdownCalls += 1 } }
    final class NullStore: StateStore { var stored: ShutdownState?; func load() -> ShutdownState? { stored }; func save(_ state: ShutdownState) { stored = state } }

    private func makeConfig(relative: Int, warnOffsets: [Int] = [60]) -> AppConfig {
        let opts = RuntimeOptions(
            relativeSeconds: relative,
            warnOffsets: warnOffsets,
            dryRun: true, // dry run so we don't exit the test process
            noPersist: true,
            postponeIntervalSeconds: nil,
            maxPostpones: nil
        )
        return AppConfig(
            dailyHour: 18,
            dailyMinute: 0,
            defaultPostponeIntervalSeconds: 600,
            defaultMaxPostpones: 2,
            defaultWarningOffsets: warnOffsets,
            options: opts
        )
    }

    func testSkipShutdownIfScheduledPreviousDay() throws {
        // Initial schedule: shutdown in 10 minutes.
        let initialNow = Date()
        let clock = FixedClock(now: initialNow)
        let config = makeConfig(relative: 600, warnOffsets: []) // no warnings needed
        let actions = TestActions()
        let scheduler = Scheduler(clock: clock)
        let controller = ShutdownController(
            config: config,
            stateStore: NullStore(),
            clock: clock,
            policy: ShutdownPolicy(),
            scheduler: scheduler,
            actions: actions,
            alertPresenter: AlertPresenter()
        )
        controller.start()

        // Advance clock to next day + 5 minutes past original scheduled shutdown.
        clock.nowValue = Calendar.current.date(byAdding: .day, value: 1, to: initialNow)!.addingTimeInterval(5 * 60)
        // Simulate timer firing late due to sleep.
        controller.shutdownDue()

        let exp = expectation(description: "drain")
        controller._testCurrentState { _ in exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(actions.shutdownCalls, 0, "Shutdown should be skipped when waking on a different day past schedule")
    }
}
