import XCTest
@testable import DailyShutdown

final class ShutdownControllerIgnoreAllowsSubsequentWarningsTests: XCTestCase {
    final class FixedClock: Clock { var nowValue: Date; init(now: Date) { self.nowValue = now }; func now() -> Date { nowValue } }
    final class CapturingAlertPresenter: AlertPresenting {
        weak var delegate: AlertPresenterDelegate?
        var presentCalls: [AlertModel] = []
        func present(model: AlertModel) { presentCalls.append(model) }
    }
    final class NullActions: SystemActions { func shutdown() {} }
    final class InMemoryStore: StateStore { var stored: ShutdownState?; func load() -> ShutdownState? { stored }; func save(_ state: ShutdownState) { stored = state } }

    private func makeConfig() -> AppConfig {
        let opts = RuntimeOptions(
            relativeSeconds: 7200, // 2h total cycle
            warnOffsets: [1800, 900, 300], // 30m, 15m, 5m warnings
            dryRun: true,
            noPersist: true,
            postponeIntervalSeconds: nil,
            maxPostpones: nil
        )
        return AppConfig(
            dailyHour: 18,
            dailyMinute: 0,
            defaultPostponeIntervalSeconds: 900,
            defaultMaxPostpones: 3,
            defaultWarningOffsets: [1800, 900, 300],
            options: opts
        )
    }

    func testIgnoreAllowsLaterWarnings() throws {
        let now = Date()
        let clock = FixedClock(now: now)
        let config = makeConfig()
        let presenter = CapturingAlertPresenter()
        let scheduler = Scheduler(clock: clock)
        let controller = ShutdownController(
            config: config,
            stateStore: InMemoryStore(),
            clock: clock,
            policy: ShutdownPolicy(),
            scheduler: scheduler,
            actions: NullActions(),
            alertPresenter: presenter
        )
        controller.start()

        // Fire first (earliest) warning (30m before)
        controller.warningDue()
        // Drain async
        let drain1 = expectation(description: "drain1")
        controller._testCurrentState { _ in drain1.fulfill() }
        wait(for: [drain1], timeout: 1.0)
        XCTAssertEqual(presenter.presentCalls.count, 1)

        // User ignores the first warning
        presenter.delegate?.userIgnored()
        let drainIgnore = expectation(description: "drainIgnore")
        controller._testCurrentState { _ in drainIgnore.fulfill() }
        wait(for: [drainIgnore], timeout: 1.0)

        // Fire second warning (15m before) -> should present again
        controller.warningDue()
        let drain2 = expectation(description: "drain2")
        controller._testCurrentState { _ in drain2.fulfill() }
        wait(for: [drain2], timeout: 1.0)
        XCTAssertEqual(presenter.presentCalls.count, 2, "Second warning should appear after ignoring first")

        // Ignore again
        presenter.delegate?.userIgnored()
        let drainIgnore2 = expectation(description: "drainIgnore2")
        controller._testCurrentState { _ in drainIgnore2.fulfill() }
        wait(for: [drainIgnore2], timeout: 1.0)

        // Fire third warning (5m before) -> should present again
        controller.warningDue()
        let drain3 = expectation(description: "drain3")
        controller._testCurrentState { _ in drain3.fulfill() }
        wait(for: [drain3], timeout: 1.0)
        XCTAssertEqual(presenter.presentCalls.count, 3, "Third warning should appear after ignoring second")
    }
}
