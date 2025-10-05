import XCTest
@testable import DailyShutdown

/// Verifies that postponing after the shutdown time has passed (while the alert was still
/// visible) does not create a new schedule or reset postpone counters; the cycle is treated
/// as finished.
final class ShutdownControllerStaleAlertPostponeTests: XCTestCase {
    final class FixedClock: Clock { var nowValue: Date; init(now: Date) { self.nowValue = now }; func now() -> Date { nowValue } }
    final class NullActions: SystemActions { func shutdown() {} }
    final class MemStore: StateStore { var stored: ShutdownState?; func load() -> ShutdownState? { stored }; func save(_ state: ShutdownState) { stored = state } }
    final class CapturingAlertPresenter: AlertPresenting {
        weak var delegate: AlertPresenterDelegate?
        var presented: [AlertModel] = []
        func present(model: AlertModel) { presented.append(model) }
    }

    private func makeConfig(seconds: Int, warnOffsets: [Int]) -> AppConfig {
        let opts = RuntimeOptions(
            relativeSeconds: seconds,
            warnOffsets: warnOffsets,
            dryRun: true,
            noPersist: true,
            postponeIntervalSeconds: 300,
            maxPostpones: 1
        )
        return AppConfig(
            dailyHour: 18,
            dailyMinute: 0,
            defaultPostponeIntervalSeconds: 300,
            defaultMaxPostpones: 1,
            defaultWarningOffsets: warnOffsets,
            options: opts
        )
    }

    func testPostponeIgnoredAfterCycleCompleteWhileAlertVisible() throws {
        let now = Date()
        let clock = FixedClock(now: now)
        let config = makeConfig(seconds: 600, warnOffsets: [300]) // warning 5m before
        let presenter = CapturingAlertPresenter()
        let scheduler = Scheduler(clock: clock)
        let store = MemStore()
        let controller = ShutdownController(
            config: config,
            stateStore: store,
            clock: clock,
            policy: ShutdownPolicy(),
            scheduler: scheduler,
            actions: NullActions(),
            alertPresenter: presenter
        )
        controller.start()

        // Fire warning -> alert visible
        controller.warningDue()
        let drain1 = expectation(description: "drain1")
        controller._testCurrentState { _ in drain1.fulfill() }
        wait(for: [drain1], timeout: 1.0)
        XCTAssertEqual(presenter.presented.count, 1)

        // Advance time beyond shutdown and trigger final event (dry run rollover while alert open)
        clock.nowValue = now.addingTimeInterval(601)
        controller.shutdownDue()
        let drain2 = expectation(description: "drain2")
        controller._testCurrentState { _ in drain2.fulfill() }
        wait(for: [drain2], timeout: 1.0)

        // Now user clicks postpone on stale alert -> should be treated as dismissal, no new postpone applied.
        presenter.delegate?.userChosePostpone()
        let drain3 = expectation(description: "drain3")
        controller._testCurrentState { st in
            XCTAssertEqual(st.postponesUsed, 0, "Postpone should be ignored after cycle completion while alert visible")
            drain3.fulfill()
        }
        wait(for: [drain3], timeout: 1.0)
    }
}
