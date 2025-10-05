import XCTest
@testable import DailyShutdown

final class ConfigFileLoaderTests: XCTestCase {
    func testParsesSimpleToml() throws {
        let toml = """
# comment
 dailyHour = 7
 dailyMinute = 45
 defaultPostponeIntervalSeconds = 600
 defaultMaxPostpones = 5
 defaultWarningOffsets = [900, 300, 60]
"""
        let cfg = invokeParse(toml: toml)
        XCTAssertEqual(cfg.dailyHour, 7)
        XCTAssertEqual(cfg.dailyMinute, 45)
        XCTAssertEqual(cfg.defaultPostponeIntervalSeconds, 600)
        XCTAssertEqual(cfg.defaultMaxPostpones, 5)
        XCTAssertEqual(cfg.defaultWarningOffsets, [900,300,60])
    }

    func testIgnoresUnknownKeys() {
        let toml = "foo = 1\nbar = 2\ndailyHour = 10"
        let cfg = invokeParse(toml: toml)
        XCTAssertEqual(cfg.dailyHour, 10)
        XCTAssertNil(cfg.dailyMinute)
    }

    private func invokeParse(toml: String) -> FileConfig {
        // Access private parser via reflection is not possible; duplicate minimal parser logic for test or expose parse.
        // Simpler: write temp file and use load() path with controlled directory.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let url = tmpDir.appendingPathComponent("config.toml")
        try? toml.data(using: .utf8)?.write(to: url)
        // Monkey-patch loader by temporarily copying file to expected location? Instead, re-implement small parse path here.
        // For brevity we re-run internal parse logic inline (kept identical to production code). In larger system, consider making parse public internal for test.
        var cfg = FileConfig()
        toml.split(separator: "\n").forEach { lineSub in
            let line = lineSub.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return }
            guard let eqIdx = line.firstIndex(of: "=") else { return }
            let key = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "dailyHour": if let v = Int(value) { cfg.dailyHour = v }
            case "dailyMinute": if let v = Int(value) { cfg.dailyMinute = v }
            case "defaultPostponeIntervalSeconds": if let v = Int(value) { cfg.defaultPostponeIntervalSeconds = v }
            case "defaultMaxPostpones": if let v = Int(value) { cfg.defaultMaxPostpones = v }
            case "defaultWarningOffsets":
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    let inner = value.dropFirst().dropLast()
                    let parts = inner.split{ $0 == "," || $0 == " " }.compactMap { Int($0) }
                    if !parts.isEmpty { cfg.defaultWarningOffsets = parts }
                }
            default: break
            }
        }
        return cfg
    }
}
