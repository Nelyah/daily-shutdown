import XCTest
@testable import DailyShutdown

final class LatePostponeGuardTests: XCTestCase {
    final class FixedClock: Clock { var nowValue: Date; init(_ now: Date) { self.nowValue = now }; func now() -> Date { nowValue } }
    final class NullActions: SystemActions { func shutdown() {} }
    final class Store: StateStore { var stored: ShutdownState?; func load() -> ShutdownState? { stored }; func save(_ state: ShutdownState) { stored = state } }
    final class Presenter: AlertPresenting { weak var delegate: AlertPresenterDelegate?; func present(model: AlertModel) {} }

    private func config(rel: Int, warnOffsets: [Int]) -> AppConfig {
        let opts = RuntimeOptions(
            relativeSeconds: rel,
            warnOffsets: warnOffsets,
            dryRun: true,
            noPersist: true,
            postponeIntervalSeconds: 300,
            maxPostpones: 2
        )
        return AppConfig(dailyHour: 18, dailyMinute: 0, defaultPostponeIntervalSeconds: 300, defaultMaxPostpones: 2, defaultWarningOffsets: warnOffsets, options: opts)
    }

    func testPostponeIgnoredAfterScheduledTimePasses() throws {
        let start = Date()
        let clock = FixedClock(start)
        let cfg = config(rel: 60, warnOffsets: []) // shutdown in 60s
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
        // Advance clock past shutdown time before attempting postpone.
        clock.nowValue = start.addingTimeInterval(120)
        controller.userChosePostpone()
        let exp = expectation(description: "state")
        controller._testCurrentState { st in
            XCTAssertEqual(st.postponesUsed, 0, "Late postpone should be ignored once deadline passed")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
