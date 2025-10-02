import XCTest
@testable import DailyShutdown

// Additional focused tests for ShutdownPolicy behaviors.
final class PolicyBehaviorTests: XCTestCase {

    private func makeConfig(relativeSeconds: Int = 3600, postpone: Int = 600, maxPostpones: Int = 2, warnOffsets: [Int]? = [900,300,60]) -> AppConfig {
        let opts = RuntimeOptions(
            relativeSeconds: relativeSeconds,
            warnOffsets: warnOffsets,
            dryRun: true,
            noPersist: true,
            postponeIntervalSeconds: postpone,
            maxPostpones: maxPostpones
        )
        return AppConfig(
            dailyHour: 18,
            dailyMinute: 0,
            defaultPostponeIntervalSeconds: postpone,
            defaultMaxPostpones: maxPostpones,
            defaultWarningOffsets: warnOffsets ?? [],
            options: opts
        )
    }

    func testCanPostponeWithinLimit() throws {
        let now = Date()
        let config = makeConfig(maxPostpones: 2)
        var state = StateFactory.newState(now: now, config: config)
        let policy = ShutdownPolicy()
        XCTAssertTrue(policy.canPostpone(state: state, config: config))
        policy.applyPostpone(state: &state, config: config, now: now)
        XCTAssertTrue(policy.canPostpone(state: state, config: config), "Should still allow second postpone")
    }

    func testCannotPostponeAtLimit() throws {
        let now = Date()
        let config = makeConfig(maxPostpones: 1)
        var state = StateFactory.newState(now: now, config: config)
        let policy = ShutdownPolicy()
        XCTAssertTrue(policy.canPostpone(state: state, config: config))
        policy.applyPostpone(state: &state, config: config, now: now)
        XCTAssertFalse(policy.canPostpone(state: state, config: config), "Should block further postpones at limit")
    }

    func testApplyPostponeAdvancesScheduleAndPreservesOriginal() throws {
        let now = Date()
        let postponeInterval = 600
        let config = makeConfig(relativeSeconds: 1800, postpone: postponeInterval, maxPostpones: 3)
        var state = StateFactory.newState(now: now, config: config)
        let original = state.originalScheduledShutdownISO
        let firstScheduled = state.scheduledShutdownISO
        let policy = ShutdownPolicy()
        policy.applyPostpone(state: &state, config: config, now: now)
        XCTAssertEqual(state.originalScheduledShutdownISO, original, "Original should not change after postpone")
        let oldDate = try XCTUnwrap(StateFactory.parseISO(firstScheduled))
        let newDate = try XCTUnwrap(StateFactory.parseISO(state.scheduledShutdownISO))
        XCTAssertEqual(newDate.timeIntervalSince(oldDate), TimeInterval(postponeInterval), accuracy: 0.5)
    }

    func testMultiplePostponesAccumulate() throws {
        let now = Date()
        let postponeInterval = 300
        let config = makeConfig(relativeSeconds: 900, postpone: postponeInterval, maxPostpones: 3)
        var state = StateFactory.newState(now: now, config: config)
        let policy = ShutdownPolicy()
        let originalScheduled = try XCTUnwrap(StateFactory.parseISO(state.scheduledShutdownISO))
        for i in 1...3 {
            policy.applyPostpone(state: &state, config: config, now: now)
            XCTAssertEqual(state.postponesUsed, i)
            let updated = try XCTUnwrap(StateFactory.parseISO(state.scheduledShutdownISO))
            let expectedDelta = TimeInterval(postponeInterval * i)
            XCTAssertEqual(updated.timeIntervalSince(originalScheduled), expectedDelta, accuracy: 0.5)
        }
        XCTAssertFalse(policy.canPostpone(state: state, config: config), "Should reach max postpones")
    }

    func testPlanAfterPostponeReflectsNewShutdown() throws {
        let now = Date()
        let config = makeConfig(relativeSeconds: 1200, postpone: 300, maxPostpones: 2, warnOffsets: [900])
        var state = StateFactory.newState(now: now, config: config)
        let policy = ShutdownPolicy()
        let initialPlan = try XCTUnwrap(policy.plan(for: state, config: config, now: now))
        let initialShutdown = initialPlan.shutdownDate
        policy.applyPostpone(state: &state, config: config, now: now)
        let newPlan = try XCTUnwrap(policy.plan(for: state, config: config, now: now))
        XCTAssertGreaterThan(newPlan.shutdownDate, initialShutdown)
    }

    func testPlanReturnsNilOnInvalidState() {
        let now = Date()
        let config = makeConfig()
        var state = StateFactory.newState(now: now, config: config)
        state.scheduledShutdownISO = "INVALID" // corrupt
        let policy = ShutdownPolicy()
        XCTAssertNil(policy.plan(for: state, config: config, now: now))
    }
}
