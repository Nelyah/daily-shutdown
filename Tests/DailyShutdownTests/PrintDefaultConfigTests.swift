import XCTest
@testable import DailyShutdown

final class PrintDefaultConfigTests: XCTestCase {
    func testDefaultConfigTomlContainsExpectedKeys() {
        let toml = CommandLineConfigParser.defaultConfigTOML()
        XCTAssertTrue(toml.contains("dailyHour"))
        XCTAssertTrue(toml.contains("dailyMinute"))
        XCTAssertTrue(toml.contains("defaultPostponeIntervalSeconds"))
        XCTAssertTrue(toml.contains("defaultMaxPostpones"))
        XCTAssertTrue(toml.contains("defaultWarningOffsets"))
        XCTAssertTrue(toml.contains("Generated at:"))
    }
}
