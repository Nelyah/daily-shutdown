import XCTest
@testable import DailyShutdown

final class PrintEffectiveConfigTests: XCTestCase {
    func testEffectiveConfigIncludesRuntimeFlags() {
        var opts = RuntimeOptions()
        opts.dryRun = true
        opts.relativeSeconds = 123
        opts.postponeIntervalSeconds = 777
        opts.maxPostpones = 9
        let cfg = AppConfig(dailyHour: 10, dailyMinute: 15, defaultPostponeIntervalSeconds: 600, defaultMaxPostpones: 3, defaultWarningOffsets: [900,300,60], options: opts)
        let toml = CommandLineConfigParser.effectiveConfigTOML(cfg)
        XCTAssertTrue(toml.contains("dailyHour = 10"))
        XCTAssertTrue(toml.contains("relativeSeconds = 123"))
        XCTAssertTrue(toml.contains("dryRun = true"))
        XCTAssertTrue(toml.contains("postponeIntervalSeconds = 777"))
        XCTAssertTrue(toml.contains("maxPostpones = 9"))
    }
}
