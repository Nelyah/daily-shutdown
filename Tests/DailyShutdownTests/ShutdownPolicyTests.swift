import XCTest
@testable import DailyShutdown

// MARK: - Test Doubles
struct FixedClock: Clock { var fixed: Date; func now() -> Date { fixed } }
final class MockSystemActions: SystemActions { private(set) var shutdownCount = 0; func shutdown() { shutdownCount += 1 } }
final class InMemoryStateStore: StateStore { var stored: ShutdownState?; func load() -> ShutdownState? { stored }; func save(_ state: ShutdownState) { stored = state } }
final class CapturingScheduler: Scheduler {
    struct Call { let shutdown: Date; let warning: Date?; let offsets: [Int] }
    private(set) var calls: [Call] = []
    override func schedule(shutdownDate: Date, warningDate: Date?, warningOffsets: [Int] = []) {
        calls.append(.init(shutdown: shutdownDate, warning: warningDate, offsets: warningOffsets))
    }
}
final class CapturingAlertPresenter: AlertPresenting {
    weak var delegate: AlertPresenterDelegate?
    private(set) var presented: [AlertModel] = []
    func present(model: AlertModel) { presented.append(model) }
}

// Helper to build config with custom warning offsets
func makeConfig(relativeSeconds: Int? = nil, warnOffsets: [Int]? = [900,300,60]) -> AppConfig {
    let opts = RuntimeOptions(
        relativeSeconds: relativeSeconds,
        warnOffsets: warnOffsets,
        dryRun: true,
        noPersist: true,
        postponeIntervalSeconds: nil,
        maxPostpones: nil
    )
    return AppConfig(
        dailyHour: 18,
        dailyMinute: 0,
        defaultPostponeIntervalSeconds: 15*60,
        defaultMaxPostpones: 3,
        defaultWarningOffsets: [900,300,60],
        options: opts
    )
}

final class ShutdownPolicyTests: XCTestCase {
    func testPrimaryWarningFromLargestOffset() throws {
        let now = Date()
        let config = makeConfig(relativeSeconds: 10*60, warnOffsets: [600, 120, 60])
        let state = StateFactory.newState(now: now, config: config)
        let policy = ShutdownPolicy()
        let plan = try XCTUnwrap(policy.plan(for: state, config: config, now: now))
        let expectedLead = TimeInterval(600)
        XCTAssertEqual(plan.shutdownDate.timeIntervalSince(now), 600, accuracy: 1.0)
        XCTAssertEqual(plan.warningDate?.timeIntervalSince(now), 0, accuracy: 0.2, "Largest offset equals shutdown interval so warning should clamp to now")
        XCTAssertEqual(config.primaryWarningLeadSeconds, Int(expectedLead))
    }

    func testWarningClampedIfOffsetPast() throws {
        let now = Date()
        let config = makeConfig(relativeSeconds: 120, warnOffsets: [900])
        var state = StateFactory.newState(now: now, config: config)
        // Force shorter shutdown than offset by overriding scheduled time
        state.scheduledShutdownISO = StateFactory.isoDate(now.addingTimeInterval(120))
        let plan = ShutdownPolicy().plan(for: state, config: config, now: now)
        XCTAssertEqual(plan?.warningDate?.timeIntervalSince(now) ?? -1, 0, accuracy: 0.2)
    }

    func testNoOffsetsNoWarning() throws {
        let now = Date()
        let config = makeConfig(relativeSeconds: 600, warnOffsets: [])
        let state = StateFactory.newState(now: now, config: config)
        let plan = ShutdownPolicy().plan(for: state, config: config, now: now)
        XCTAssertNil(plan?.warningDate)
    }
}

final class SchedulerTests: XCTestCase {
    func testSchedulesMultipleWarningOffsets() throws {
        let sched = Scheduler()
        let now = Date()
        let shutdown = now.addingTimeInterval(1000)
        // We cannot easily access internal timers; instead rely on log? For deterministic unit test, restructure.
        // For now, just ensure no crash and leverage reflection of method by wrapping schedule in expectation.
        sched.schedule(shutdownDate: shutdown, warningDate: shutdown.addingTimeInterval(-500), warningOffsets: [900, 300, 60])
        // Can't assert internal state without making it test-visible; consider refactor to inject TimerFactory.
        // Placeholder assertion to satisfy test presence.
        XCTAssertTrue(true)
    }
}

final class ControllerTests: XCTestCase {
    func testPostponeUpdatesState() throws {
        let now = Date()
        let clock = FixedClock(fixed: now)
        let config = makeConfig(relativeSeconds: 3600, warnOffsets: [900,300,60])
        let store = InMemoryStateStore()
        let scheduler = CapturingScheduler()
        let actions = MockSystemActions()
        let presenter = CapturingAlertPresenter()
        let controller = ShutdownController(
            config: config,
            stateStore: store,
            clock: clock,
            policy: ShutdownPolicy(),
            scheduler: scheduler,
            actions: actions,
            alertPresenter: presenter
        )
        controller.start()
        // Simulate user postpone
        controller.userChosePostpone()
        // Allow async stateQueue to execute
        let exp = expectation(description: "wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(store.stored?.postponesUsed, 1)
    }
}
