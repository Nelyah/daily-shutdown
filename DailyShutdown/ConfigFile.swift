import Foundation

/// Simple TOML configuration loader. External file allows user to provide defaults without CLI flags.
/// Precedence (highest first): CLI flags > user preferences (if implemented) > config file > built-in defaults.
/// We intentionally implement a minimal subset of TOML needed for expected keys.
/// Expected TOML keys (all optional):
///   dailyHour = 18
///   dailyMinute = 0
///   defaultPostponeIntervalSeconds = 900
///   defaultMaxPostpones = 3
///   defaultWarningOffsets = [900,300,60]
/// File location: "$HOME/Library/Application Support/DailyShutdown/config.toml" (macOS standard app support path).
struct FileConfig: Equatable {
    var dailyHour: Int?
    var dailyMinute: Int?
    var defaultPostponeIntervalSeconds: Int?
    var defaultMaxPostpones: Int?
    var defaultWarningOffsets: [Int]?
}

enum ConfigFileLoader {
    static func load() -> FileConfig {
        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DailyShutdown", isDirectory: true)
        let url = baseDir.appendingPathComponent("config.toml")
        guard let data = try? Data(contentsOf: url), let raw = String(data: data, encoding: .utf8) else { return FileConfig() }
        return parse(toml: raw)
    }

    // Extremely small TOML-ish parser targeting simple key = value and array syntax for our keys only.
    private static func parse(toml: String) -> FileConfig {
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

extension CommandLineConfigParser {
    /// Compose final AppConfig by layering config file under runtime CLI options.
    /// CLI flags (already parsed) override file values for overlapping fields.
    static func parseWithFile(arguments: [String] = CommandLine.arguments) -> AppConfig {
        let cli = parse(arguments: arguments)
        let fileCfg = ConfigFileLoader.load()
        // Build base defaults using file overrides if present, else fallback to existing cli defaults.
        return AppConfig(
            dailyHour: fileCfg.dailyHour ?? cli.dailyHour,
            dailyMinute: fileCfg.dailyMinute ?? cli.dailyMinute,
            defaultPostponeIntervalSeconds: fileCfg.defaultPostponeIntervalSeconds ?? cli.defaultPostponeIntervalSeconds,
            defaultMaxPostpones: fileCfg.defaultMaxPostpones ?? cli.defaultMaxPostpones,
            defaultWarningOffsets: fileCfg.defaultWarningOffsets ?? cli.defaultWarningOffsets,
            options: cli.options // runtime overrides preserved
        )
    }
}
