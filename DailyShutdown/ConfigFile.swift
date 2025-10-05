import Foundation
import TOMLDecoder

/// Overrides loaded from `config.toml`. Supports both base default fields and runtime option
/// fields (so users can put most settings in the file). All properties are optional; absent
/// values leave underlying defaults intact.
struct ConfigFileOverrides: Equatable {
    // Base defaults
    var dailyHour: Int?
    var dailyMinute: Int?
    var defaultPostponeIntervalSeconds: Int?
    var defaultMaxPostpones: Int?
    var defaultWarningOffsets: [Int]?
    // Runtime options
    var relativeSeconds: Int?
    var warnOffsets: [Int]?
    var dryRun: Bool?
    var noPersist: Bool?
    var postponeIntervalSeconds: Int?
    var maxPostpones: Int?
}

enum ConfigFileLoader {
    /// Locate and parse the TOML config file returning overrides (all optionals).
    static func loadOverrides() -> ConfigFileOverrides {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let xdgBase: URL = {
            if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { return URL(fileURLWithPath: xdg, isDirectory: true) }
            return fm.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }()
        let path = xdgBase.appendingPathComponent("daily-shutdown", isDirectory: true).appendingPathComponent("config.toml")
        guard let data = try? Data(contentsOf: path), let raw = String(data: data, encoding: .utf8) else { return ConfigFileOverrides() }
        return parseToml(raw)
    }

    /// Minimal TOML subset parser for key=value & integer arrays. Bool parsing supports true/false.
    // For compatibility with previous code; now replaced by TOMLDecoder.
    static func parseToml(_ toml: String) -> ConfigFileOverrides {
        struct FileConfigDecodable: Decodable {
            var dailyHour: Int?
            var dailyMinute: Int?
            var defaultPostponeIntervalSeconds: Int?
            var defaultMaxPostpones: Int?
            var defaultWarningOffsets: [Int]?
            var relativeSeconds: Int?
            var warnOffsets: [Int]?
            var dryRun: Bool?
            var noPersist: Bool?
            var postponeIntervalSeconds: Int?
            var maxPostpones: Int?
        }
        let decoder = TOMLDecoder()
        guard let model = try? decoder.decode(FileConfigDecodable.self, from: toml) else { return ConfigFileOverrides() }
        return ConfigFileOverrides(
            dailyHour: model.dailyHour,
            dailyMinute: model.dailyMinute,
            defaultPostponeIntervalSeconds: model.defaultPostponeIntervalSeconds,
            defaultMaxPostpones: model.defaultMaxPostpones,
            defaultWarningOffsets: model.defaultWarningOffsets,
            relativeSeconds: model.relativeSeconds,
            warnOffsets: model.warnOffsets,
            dryRun: model.dryRun,
            noPersist: model.noPersist,
            postponeIntervalSeconds: model.postponeIntervalSeconds,
            maxPostpones: model.maxPostpones
        )
    }
}

extension CommandLineConfigParser {
    /// Compose final AppConfig by layering (low→high): built-in defaults < file overrides < CLI flags.
    static func parseWithFile(arguments: [String] = CommandLine.arguments) -> AppConfig {
        // Parse CLI to obtain user-specified runtime flags.
        let cli = parse(arguments: arguments)
        let file = ConfigFileLoader.loadOverrides()

        // Start from built-in defaults.
        var dailyHour = 18
        var dailyMinute = 0
        var defaultPostponeIntervalSeconds = 15 * 60
        var defaultMaxPostpones = 3
        var defaultWarningOffsets = [15*60, 5*60, 60]

        // Apply file overrides if present.
        if let v = file.dailyHour { dailyHour = v }
        if let v = file.dailyMinute { dailyMinute = v }
        if let v = file.defaultPostponeIntervalSeconds { defaultPostponeIntervalSeconds = v }
        if let v = file.defaultMaxPostpones { defaultMaxPostpones = v }
        if let v = file.defaultWarningOffsets, !v.isEmpty { defaultWarningOffsets = v }

        // Merge runtime options: start with file-level runtime overrides then let CLI take precedence.
        var mergedOpts = cli.options // CLI already parsed
        if mergedOpts.relativeSeconds == nil, let v = file.relativeSeconds { mergedOpts.relativeSeconds = v }
        if mergedOpts.warnOffsets == nil, let v = file.warnOffsets { mergedOpts.warnOffsets = v }
        if file.dryRun == true { mergedOpts.dryRun = true } // can't negate
        if file.noPersist == true { mergedOpts.noPersist = true }
        if mergedOpts.postponeIntervalSeconds == nil, let v = file.postponeIntervalSeconds { mergedOpts.postponeIntervalSeconds = v }
        if mergedOpts.maxPostpones == nil, let v = file.maxPostpones { mergedOpts.maxPostpones = v }

        return AppConfig(
            dailyHour: dailyHour,
            dailyMinute: dailyMinute,
            defaultPostponeIntervalSeconds: defaultPostponeIntervalSeconds,
            defaultMaxPostpones: defaultMaxPostpones,
            defaultWarningOffsets: defaultWarningOffsets,
            options: mergedOpts
        )
    }
}
