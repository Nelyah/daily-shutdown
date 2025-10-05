import XCTest
@testable import DailyShutdown

final class ConfigFileDecodeFailureTests: XCTestCase {
    final class CaptureLogger: Logger {
        private(set) var messages: [String] = []
        func info(_ message: @autoclosure () -> String) { messages.append(message()) }
        func error(_ message: @autoclosure () -> String) { messages.append(message()) }
    }

    override func tearDown() {
        unsetenv("DAILY_SHUTDOWN_CONFIG_PATH")
        super.tearDown()
    }

    func testMalformedTomlLogsDecodeFailure() throws {
        // Intentionally malformed (missing closing bracket and equals misuse)
        let badToml = "dailyHour == 18\n defaultWarningOffsets = [900, 300,"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let cfgPath = tmp.appendingPathComponent("config.toml")
        try badToml.write(to: cfgPath, atomically: true, encoding: .utf8)
        setenv("DAILY_SHUTDOWN_CONFIG_PATH", cfgPath.path, 1)

        let cap = CaptureLogger(); logger = cap
        _ = CommandLineConfigParser.parseWithFile(arguments: [CommandLine.arguments.first ?? "daily-shutdown"])
        let decodeLog = cap.messages.first { $0.contains("TOML decode failed") }
        XCTAssertNotNil(decodeLog, "Expected a decode failure log entry")
    }

    func testOversizeFileIgnored() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let cfgPath = tmp.appendingPathComponent("config.toml")
        // Create > 256 KB file
        let big = String(repeating: "#", count: 300_000)
        try big.write(to: cfgPath, atomically: true, encoding: .utf8)
        setenv("DAILY_SHUTDOWN_CONFIG_PATH", cfgPath.path, 1)
        let cap = CaptureLogger(); logger = cap
        _ = CommandLineConfigParser.parseWithFile(arguments: [CommandLine.arguments.first ?? "daily-shutdown"])
        XCTAssertTrue(cap.messages.contains { $0.contains("exceeds size cap") })
    }
}
