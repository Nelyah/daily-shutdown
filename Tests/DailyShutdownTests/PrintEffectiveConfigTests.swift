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

    func testEffectiveConfigCommentsUnsetRuntimeOptions() {
        // No runtime overrides set
        let cfg = AppConfig(dailyHour: 18, dailyMinute: 0, defaultPostponeIntervalSeconds: 900, defaultMaxPostpones: 3, defaultWarningOffsets: [900,300,60], options: RuntimeOptions())
        let toml = CommandLineConfigParser.effectiveConfigTOML(cfg)
        XCTAssertTrue(toml.contains("# relativeSeconds = (unset)"))
        XCTAssertTrue(toml.contains("# warnOffsets = (unset)"))
        XCTAssertTrue(toml.contains("# dryRun = false"))
        XCTAssertTrue(toml.contains("# noPersist = false"))
        XCTAssertTrue(toml.contains("# postponeIntervalSeconds = (unset)"))
        XCTAssertTrue(toml.contains("# maxPostpones = (unset)"))
    }

    func testEffectiveConfigWarnOffsetsOverrideShownNotCommented() {
        var opts = RuntimeOptions()
        opts.warnOffsets = [1200, 600, 60]
        let cfg = AppConfig(dailyHour: 8, dailyMinute: 30, defaultPostponeIntervalSeconds: 600, defaultMaxPostpones: 4, defaultWarningOffsets: [900,300,60], options: opts)
        let toml = CommandLineConfigParser.effectiveConfigTOML(cfg)
        XCTAssertTrue(toml.contains("warnOffsets = [1200, 600, 60]"), "Expected concrete warnOffsets line when override present")
        XCTAssertFalse(toml.contains("# warnOffsets = (unset)"), "Unset comment should not appear when override present")
    }
}
