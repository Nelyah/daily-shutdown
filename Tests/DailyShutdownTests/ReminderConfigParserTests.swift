import XCTest
@testable import DailyShutdown

final class ReminderConfigParserTests: XCTestCase {
    func testParsesValidSingleItem() {
        let toml = """
        [[reminders.items]]
        id = "stretch"
        startTime = "10:15"
        intervalSeconds = 300
        prompt = "Stretch now"
        requiredText = "DONE"
        caseInsensitive = true
        """
        let result = parseReminderConfig(from: toml)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.config.items.count, 1)
        let item = result.config.items[0]
        XCTAssertEqual(item.id, "stretch")
        XCTAssertEqual(item.startHour, 10)
        XCTAssertEqual(item.startMinute, 15)
        XCTAssertEqual(item.intervalSeconds, 300)
        XCTAssertEqual(item.requiredText, "DONE")
        XCTAssertTrue(item.caseInsensitive)
    }

    func testIntervalClampedBelowMinimum() {
        let toml = """
        [[reminders.items]]
        id = "test"
        startTime = "05:00"
        intervalSeconds = 5
        prompt = "p"
        requiredText = "X"
        """
        let r = parseReminderConfig(from: toml)
        XCTAssertTrue(r.errors.isEmpty)
        XCTAssertEqual(r.config.items.first?.intervalSeconds, 30)
        XCTAssertTrue(r.warnings.contains { $0.contains("clamped") })
    }

    func testDuplicateIdsWarnAndKeepFirst() {
        let toml = """
        [[reminders.items]]
        id = "dup"
        startTime = "07:00"
        intervalSeconds = 300
        prompt = "p1"
        requiredText = "A"
        [[reminders.items]]
        id = "dup"
        startTime = "08:00"
        intervalSeconds = 600
        prompt = "p2"
        requiredText = "B"
        """
        let r = parseReminderConfig(from: toml)
        XCTAssertEqual(r.config.items.count, 1)
        XCTAssertTrue(r.warnings.contains { $0.contains("duplicate") })
        XCTAssertEqual(r.config.items[0].startHour, 7)
    }

    func testInvalidStartTimeProducesError() {
        let toml = """
        [[reminders.items]]
        id = "bad"
        startTime = "99:99"
        intervalSeconds = 300
        prompt = "p"
        requiredText = "R"
        """
        let r = parseReminderConfig(from: toml)
        XCTAssertTrue(r.errors.contains { $0.contains("invalid startTime") })
        XCTAssertTrue(r.config.items.isEmpty)
    }

    func testMissingRequiredTextError() {
        let toml = """
        [[reminders.items]]
        id = "bad2"
        startTime = "09:10"
        intervalSeconds = 300
        prompt = "p"
        """
        let r = parseReminderConfig(from: toml)
        XCTAssertTrue(r.errors.contains { $0.contains("missing requiredText") })
        XCTAssertTrue(r.config.items.isEmpty)
    }
}
