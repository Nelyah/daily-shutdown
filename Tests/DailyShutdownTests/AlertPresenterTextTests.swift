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
            postponeIntervalMinutes: 10
        )
        let text = AlertPresenter.buildInformativeText(model: model, dateFormatter: df)
        XCTAssertTrue(text.contains("You may postpone up to 2 more time(s)."), "Expected remaining postpones phrasing")
        XCTAssertFalse(text.contains("No postpones remaining."))
    }

    func testInformativeTextWhenNoPostponesRemain() {
        let df = DateFormatter(); df.timeStyle = .short
        let now = Date()
        let model = AlertModel(
            scheduled: now.addingTimeInterval(600),
            original: now.addingTimeInterval(600),
            postponesUsed: 2,
            maxPostpones: 2,
            postponeIntervalMinutes: 10
        )
        let text = AlertPresenter.buildInformativeText(model: model, dateFormatter: df)
        XCTAssertTrue(text.contains("No postpones remaining."))
        XCTAssertFalse(text.contains("You may postpone up to"))
    }
}
