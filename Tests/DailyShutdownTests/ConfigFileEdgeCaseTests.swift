import XCTest
@testable import DailyShutdown

final class ConfigFileEdgeCaseTests: XCTestCase {
    final class CaptureLogger: Logger {
        var messages: [String] = []
        func info(_ message: @autoclosure () -> String) { messages.append(message()) }
        func error(_ message: @autoclosure () -> String) { messages.append(message()) }
    }

    override func tearDown() {
        unsetenv("DAILY_SHUTDOWN_CONFIG_PATH")
        super.tearDown()
    }

    func testConfigPathEnvPointsToUnreadableFile() throws {
        // Point to a non-existent file path.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing-config.toml")
        setenv("DAILY_SHUTDOWN_CONFIG_PATH", tmp.path, 1)
        let cap = CaptureLogger(); logger = cap
        let cfg = CommandLineConfigParser.parseWithFile(arguments: [CommandLine.arguments.first ?? "daily-shutdown"])
        // Should fall back to defaults
        XCTAssertEqual(cfg.dailyHour, 18)
        XCTAssertTrue(cap.messages.contains { $0.contains("explicit path set but not readable") })
    }

    func testNonUtf8FileIgnored() throws {
        // Write bytes that are invalid UTF-8 by truncating a multi-byte sequence.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let fileURL = tmpDir.appendingPathComponent("config.toml")
        var data = Data([0xFF, 0xFE, 0xFA]) // invalid leading bytes for UTF-8 content
        try data.write(to: fileURL)
        setenv("DAILY_SHUTDOWN_CONFIG_PATH", fileURL.path, 1)
        let cap = CaptureLogger(); logger = cap
        _ = CommandLineConfigParser.parseWithFile(arguments: [CommandLine.arguments.first ?? "daily-shutdown"])
        XCTAssertTrue(cap.messages.contains { $0.contains("explicit path set but not readable") })
    }

    func testSizeCapEnforcedForStandardPath() throws {
        // Create XDG config home with oversize file
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let configDir = tmpDir.appendingPathComponent("daily-shutdown")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let cfg = configDir.appendingPathComponent("config.toml")
        let big = String(repeating: "#", count: 300_000)
        try big.write(to: cfg, atomically: true, encoding: .utf8)
        setenv("XDG_CONFIG_HOME", tmpDir.path, 1)
        defer { unsetenv("XDG_CONFIG_HOME") }
        let cap = CaptureLogger(); logger = cap
        _ = CommandLineConfigParser.parseWithFile(arguments: [CommandLine.arguments.first ?? "daily-shutdown"])
        XCTAssertTrue(cap.messages.contains { $0.contains("file exceeds size cap") })
    }
}
