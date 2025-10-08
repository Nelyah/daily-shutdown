import XCTest
@testable import DailyShutdown
final class AlertPresenterTextTests: XCTestCase {
    func testInformativeTextWhenPostponesRemain() {
        let df = DateFormatter(); df.timeStyle = .short
        let now = Date()
        let model = AlertModel(
            scheduled: now.addingTimeInterval(600),
            original: now.addingTimeInterval(600),
            postponesUsed: 0,
            maxPostpones: 2,
            postponeIntervalSeconds: 600
        )
        let text = AlertPresenter.buildInformativeText(model: model, dateFormatter: df, now: now)
        XCTAssertTrue(text.contains("Scheduled:"))
        XCTAssertFalse(text.contains("Original:"))
        XCTAssertTrue(text.contains("2 postpones remaining"))
    }

    func testCountdownDecrementsWithInjectedNow() {
        let df = DateFormatter(); df.timeStyle = .short
        let base = Date()
        let model = AlertModel(
            scheduled: base.addingTimeInterval(65), // 65 seconds out
            original: base.addingTimeInterval(65),
            postponesUsed: 0,
            maxPostpones: 1,
            postponeIntervalSeconds: 300
        )
        let t0 = AlertPresenter.buildInformativeText(model: model, dateFormatter: df, now: base)
        let t1 = AlertPresenter.buildInformativeText(model: model, dateFormatter: df, now: base.addingTimeInterval(10))
        let t2 = AlertPresenter.buildInformativeText(model: model, dateFormatter: df, now: base.addingTimeInterval(64))
        // Expect seconds countdown strings inside parentheses to decrease.
        XCTAssertTrue(t0.contains("in 1m"))
        XCTAssertTrue(t1.contains("in 55s")) // 65 - 10 = 55
        XCTAssertTrue(t2.contains("in 1s") || t2.contains("in 0s")) // clamp at zero on final second
    }
}

final class AlertPresenterButtonTitleTests: XCTestCase {
    func testSecondsRenderingUnderTwoMinutes() {
        XCTAssertEqual(AlertPresenter.postponeButtonTitle(seconds: 30), "Postpone 30 sec")
        XCTAssertEqual(AlertPresenter.postponeButtonTitle(seconds: 119), "Postpone 119 sec")
    }
    func testMinutesRenderingAtOrAboveTwoMinutes() {
        XCTAssertEqual(AlertPresenter.postponeButtonTitle(seconds: 120), "Postpone 2 min")
        XCTAssertEqual(AlertPresenter.postponeButtonTitle(seconds: 181), "Postpone 3 min") // rounds 181/60 ~ 3
    }
}

final class AlertPresenterTextNoRemainingTests: XCTestCase {
    func testInformativeTextWhenNoPostponesRemain() {
        let df = DateFormatter(); df.timeStyle = .short
        let now = Date()
        let model = AlertModel(
            scheduled: now.addingTimeInterval(600),
            original: now.addingTimeInterval(600),
            postponesUsed: 2,
            maxPostpones: 2,
            postponeIntervalSeconds: 600
        )
        let text = AlertPresenter.buildInformativeText(model: model, dateFormatter: df, now: now)
        XCTAssertTrue(text.contains("No postpones remaining"))
        // Ensure singular form not incorrectly used for >1 remaining.
        XCTAssertFalse(text.contains("2 postpones remaining"))
    }
}
