import XCTest
@testable import DailyShutdown

final class ConfigFileValidationTests: XCTestCase {
    final class CapturingLogger: Logger {
        struct Entry { let level: String; let message: String }
        private(set) var entries: [Entry] = []
        func info(_ message: @autoclosure () -> String) { entries.append(.init(level: "INFO", message: message())) }
        func error(_ message: @autoclosure () -> String) { entries.append(.init(level: "ERROR", message: message())) }
    }

    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        unsetenv("DAILY_SHUTDOWN_CONFIG_PATH")
        super.tearDown()
    }

    func testInvalidValuesProduceWarningsAndNormalization() throws {
        let toml = """
# invalid config values
 dailyHour = 99
 dailyMinute = 75
 defaultPostponeIntervalSeconds = 0
 defaultMaxPostpones = -2
 defaultWarningOffsets = [900, 0, 300, 300, -5]
 relativeSeconds = -10
 warnOffsets = [300, 300, 60, 0]
 postponeIntervalSeconds = -15
 maxPostpones = -1
"""
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let cfgPath = tmp.appendingPathComponent("config.toml")
        try toml.write(to: cfgPath, atomically: true, encoding: .utf8)
        setenv("DAILY_SHUTDOWN_CONFIG_PATH", cfgPath.path, 1)

        let capture = CapturingLogger(); logger = capture
        let merged = CommandLineConfigParser.parseWithFile(arguments: [CommandLine.arguments.first ?? "daily-shutdown"])

        // Out of range hour/minute should fall back to defaults (18:0)
        XCTAssertEqual(merged.dailyHour, 18)
        XCTAssertEqual(merged.dailyMinute, 0)
        // Zero / negative defaults removed -> fallback to defaults 15*60,5*60,60 (after normalization)
        XCTAssertEqual(merged.defaultPostponeIntervalSeconds, 15*60)
        XCTAssertEqual(merged.defaultMaxPostpones, 3)
        // Offsets normalized (remove <=0, dedupe, sort desc) produced [900,300]; since 60 not provided or added, expect [900,300]
        XCTAssertEqual(merged.defaultWarningOffsets, [900,300])
        // Relative seconds invalid removed
        XCTAssertNil(merged.options.relativeSeconds)
        // warnOffsets normalized (60,300 -> [300,60]) but will be stored deduped descending
        XCTAssertEqual(merged.options.warnOffsets, [300,60])
        // Negative postpone / max removed
        XCTAssertNil(merged.options.postponeIntervalSeconds)
        XCTAssertNil(merged.options.maxPostpones)

        let warningLines = capture.entries.filter { $0.message.hasPrefix("Config warning:") }
        XCTAssertGreaterThanOrEqual(warningLines.count, 1, "Expected warning lines for invalid values")
        // Spot check a few warnings
        XCTAssertTrue(warningLines.contains { $0.message.contains("dailyHour out of range") })
        XCTAssertTrue(warningLines.contains { $0.message.contains("dailyMinute out of range") })
        XCTAssertTrue(warningLines.contains { $0.message.contains("defaultPostponeIntervalSeconds") })
        XCTAssertTrue(warningLines.contains { $0.message.contains("relativeSeconds") })
    }
}
