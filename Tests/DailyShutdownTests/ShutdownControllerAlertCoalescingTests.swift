import XCTest
@testable import DailyShutdown

final class ShutdownControllerAlertCoalescingTests: XCTestCase {
    // MARK: - Test Doubles
    final class FixedClock: Clock { var nowValue: Date; init(now: Date) { self.nowValue = now }; func now() -> Date { nowValue } }
    final class DummyPolicy: ShutdownPolicyType {
        func plan(for state: ShutdownState, config: AppConfig, now: Date) -> SchedulePlan? {
            // Always schedule a shutdown one hour from now with no explicit legacy warning date.
            return SchedulePlan(shutdownDate: now.addingTimeInterval(3600), warningDate: nil)
        }
        func canPostpone(state: ShutdownState, config: AppConfig) -> Bool { true }
        func applyPostpone(state: inout ShutdownState, config: AppConfig, now: Date) { }
    }
    final class CapturingAlertPresenter: AlertPresenting {
        weak var delegate: AlertPresenterDelegate?
        var presentCalls: [AlertModel] = []
        func present(model: AlertModel) { presentCalls.append(model) }
    }
    final class NullActions: SystemActions { func shutdown() {} }
    final class InMemoryStore: StateStore { var stored: ShutdownState?; func load() -> ShutdownState? { stored }; func save(_ state: ShutdownState) { stored = state } }

    private func makeConfig() -> AppConfig {
        let opts = RuntimeOptions(
            relativeSeconds: 7200, // 2h
            warnOffsets: [900], // single warning offset 15m
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
            defaultWarningOffsets: [900],
            options: opts
        )
    }

    func testSecondWarningSkippedWhileAlertActive() throws {
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

        // Simulate first warning firing.
        controller.warningDue()
        // Simulate second warning firing before user interacted.
        controller.warningDue()

        // Allow async state queue to drain.
        let exp1 = expectation(description: "drain")
        controller._testCurrentState { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)

        XCTAssertEqual(presenter.presentCalls.count, 1, "Second warning should be coalesced while alert active")

        // Simulate user ignoring -> clears active flag
        presenter.delegate?.userIgnored()

        // Third warning after dismissal should NOT present again in same cycle (suppressed).
        controller.warningDue()
        let exp2 = expectation(description: "drain2")
        controller._testCurrentState { _ in exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)
        XCTAssertEqual(presenter.presentCalls.count, 1, "Warning after dismissal should remain suppressed until postpone or cycle change")
    }
}
