import XCTest
@testable import DailyShutdown

final class HelpFlagTests: XCTestCase {
    func testHelpTextContainsAllFlags() {
        let help = CommandLineConfigParser.helpText
        XCTAssertTrue(help.contains("--in-seconds"))
        XCTAssertTrue(help.contains("--warn-offsets"))
        XCTAssertTrue(help.contains("--postpone-sec"))
        XCTAssertTrue(help.contains("--max-postpones"))
        XCTAssertTrue(help.contains("--dry-run"))
        XCTAssertTrue(help.contains("--no-persist"))
        XCTAssertTrue(help.contains("-h, --help"))
    }
}
