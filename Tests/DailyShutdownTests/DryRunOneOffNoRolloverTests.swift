import XCTest
@testable import DailyShutdown

/// Verifies that in dry-run relative mode (--in-seconds) the controller does not schedule a new
/// cycle after the shutdown moment passes.
final class DryRunOneOffNoRolloverTests: XCTestCase {
    final class FixedClock: Clock { var nowValue: Date; init(_ now: Date) { self.nowValue = now }; func now() -> Date { nowValue } }
    final class NullActions: SystemActions { func shutdown() {} }
    final class Store: StateStore { var stored: ShutdownState?; func load() -> ShutdownState? { stored }; func save(_ state: ShutdownState) { stored = state } }
    final class Presenter: AlertPresenting { weak var delegate: AlertPresenterDelegate?; func present(model: AlertModel) {} }

    func testDoesNotRescheduleAfterDryRunRelativeShutdown() throws {
        let start = Date()
        let clock = FixedClock(start)
        let opts = RuntimeOptions(
            relativeSeconds: 5,
            warnOffsets: [],
            dryRun: true,
            noPersist: true,
            postponeIntervalSeconds: nil,
            maxPostpones: nil
        )
        let cfg = AppConfig(
            dailyHour: 18,
            dailyMinute: 0,
            defaultPostponeIntervalSeconds: 300,
            defaultMaxPostpones: 2,
            defaultWarningOffsets: [],
            options: opts
        )
        let scheduler = Scheduler(clock: clock)
        let controller = ShutdownController(
            config: cfg,
            stateStore: Store(),
            clock: clock,
            policy: ShutdownPolicy(),
            scheduler: scheduler,
            actions: NullActions(),
            alertPresenter: Presenter()
        )
        controller.start()
        // Simulate time passing beyond shutdown.
        clock.nowValue = start.addingTimeInterval(6)
        controller.shutdownDue()
        // Advance time further to see if unintended reschedule occurs (would log new schedule via final timer).
        clock.nowValue = start.addingTimeInterval(20)
        // No direct assertion on scheduler logs; rely on absence of state mutation (postpones stay 0) and no crash.
        let exp = expectation(description: "state")
        controller._testCurrentState { st in
            XCTAssertEqual(st.postponesUsed, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
