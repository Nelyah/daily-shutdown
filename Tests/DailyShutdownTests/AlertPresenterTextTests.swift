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
        let text = AlertPresenter.buildInformativeText(model: model, dateFormatter: df)
        XCTAssertTrue(text.contains("You may postpone up to 2 more time(s)."), "Expected remaining postpones phrasing")
        XCTAssertFalse(text.contains("No postpones remaining."))
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
        let text = AlertPresenter.buildInformativeText(model: model, dateFormatter: df)
        XCTAssertTrue(text.contains("No postpones remaining."))
        XCTAssertFalse(text.contains("You may postpone up to"))
    }
}
