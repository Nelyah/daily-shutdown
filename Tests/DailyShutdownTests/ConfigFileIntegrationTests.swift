import XCTest
@testable import DailyShutdown

final class ConfigFileIntegrationTests: XCTestCase {
    func testFileOverridesMerged() throws {
        // Create a temporary TOML config file.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let fileURL = tmpDir.appendingPathComponent("config.toml")
        let toml = """
# sample config
 dailyHour = 7
 dailyMinute = 15
 defaultPostponeIntervalSeconds = 600
 defaultMaxPostpones = 5
 defaultWarningOffsets = [1200, 600, 60]
 relativeSeconds = 7200
 warnOffsets = [900, 300]
 dryRun = true
 noPersist = true
 postponeIntervalSeconds = 450
 maxPostpones = 8
"""
        try toml.write(to: fileURL, atomically: true, encoding: .utf8)

        // Set environment override path.
        setenv("DAILY_SHUTDOWN_CONFIG_PATH", fileURL.path, 1)
        // Parse with no CLI args beyond executable.
        let cfg = CommandLineConfigParser.parseWithFile(arguments: [CommandLine.arguments.first ?? "daily-shutdown"])

        XCTAssertEqual(cfg.dailyHour, 7)
        XCTAssertEqual(cfg.dailyMinute, 15)
        XCTAssertEqual(cfg.defaultPostponeIntervalSeconds, 600)
        XCTAssertEqual(cfg.defaultMaxPostpones, 5)
        XCTAssertEqual(cfg.defaultWarningOffsets, [1200, 600, 60])
        XCTAssertEqual(cfg.options.relativeSeconds, 7200)
        XCTAssertEqual(cfg.options.warnOffsets ?? [], [900, 300])
        XCTAssertTrue(cfg.options.dryRun)
        XCTAssertTrue(cfg.options.noPersist)
        XCTAssertEqual(cfg.options.postponeIntervalSeconds, 450)
        XCTAssertEqual(cfg.options.maxPostpones, 8)

        // Cleanup the env var to avoid cross-test interference.
        unsetenv("DAILY_SHUTDOWN_CONFIG_PATH")
    }
}
