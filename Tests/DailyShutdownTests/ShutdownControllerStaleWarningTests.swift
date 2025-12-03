import XCTest
@testable import DailyShutdown

/// Tests covering wake-from-sleep stale warning guard: we only show a warning if now is the same
/// calendar day as the originally scheduled shutdown. If the machine wakes on a later day
/// past a warning time, the warning is skipped and a new cycle is created.
final class ShutdownControllerStaleWarningTests: XCTestCase {
    final class FixedClock: Clock { var nowValue: Date; init(now: Date) { self.nowValue = now }; func now() -> Date { nowValue } }
    final class TestActions: SystemActions { var shutdownCalls = 0; func shutdown() { shutdownCalls += 1 } }
    final class NullStore: StateStore { var stored: ShutdownState?; func load() -> ShutdownState? { stored }; func save(_ state: ShutdownState) { stored = state } }
    final class TestAlertPresenter: AlertPresenting {
        var presented = false
        var delegate: AlertPresenterDelegate?
        func present(model: AlertModel) {
            presented = true
        }
    }

    private func makeConfig(relative: Int, warnOffsets: [Int] = [60]) -> AppConfig {
        let opts = RuntimeOptions(
            relativeSeconds: relative,
            warnOffsets: warnOffsets,
            dryRun: true,
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

    func testSkipWarningIfScheduledPreviousDay() throws {
        // Initial schedule: shutdown in 10 minutes (600s), with a warning at 1 minute before (offset 60s).
        // This means the warning should fire in 9 minutes (540s).
        let initialNow = Date()
        let clock = FixedClock(now: initialNow)
        let config = makeConfig(relative: 600, warnOffsets: [60])
        let actions = TestActions()
        let alertPresenter = TestAlertPresenter()
        let scheduler = Scheduler(clock: clock)
        let controller = ShutdownController(
            config: config,
            stateStore: NullStore(),
            clock: clock,
            policy: ShutdownPolicy(),
            scheduler: scheduler,
            actions: actions,
            alertPresenter: alertPresenter
        )
        controller.start()

        // Advance clock to the next day, past the warning time.
        // The warning was due at initialNow + 540s.
        // We wake at next day, 541s after initial start.
        clock.nowValue = Calendar.current.date(byAdding: .day, value: 1, to: initialNow)!.addingTimeInterval(541)

        // Simulate the warning timer firing late due to sleep.
        controller.warningDue()

        let exp = expectation(description: "drain")
        controller._testCurrentState { state in
            // We need to give time for the async block in warningDue to run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertFalse(alertPresenter.presented, "Warning alert should not be presented when waking on a different day")

                // Also verify that a new state for the new day has been created.
                let stateDay = Calendar.current.startOfDay(for: StateFactory.parseISO(state.originalScheduledShutdownISO)!)
                let nowDay = Calendar.current.startOfDay(for: clock.now())
                XCTAssertEqual(stateDay, nowDay, "A new state for the current day should have been created")

                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
}
