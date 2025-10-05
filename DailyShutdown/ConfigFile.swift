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
    private static let maxConfigBytes: Int = 256 * 1024 // 256 KB safety cap
    /// Locate and parse the TOML config file returning overrides (all optionals).
    static func loadOverrides() -> ConfigFileOverrides {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        // Test / power-user override: if DAILY_SHUTDOWN_CONFIG_PATH is set, use it directly.
        if let explicit = env["DAILY_SHUTDOWN_CONFIG_PATH"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit, isDirectory: false)
            if let data = try? Data(contentsOf: url) {
                if data.count > maxConfigBytes {
                    log("Config: explicit file exceeds size cap (\(data.count) > \(maxConfigBytes)) ignoring")
                    return ConfigFileOverrides()
                }
                if let raw = String(data: data, encoding: .utf8) {
                    let overrides = parseToml(raw)
                    let (validated, warnings) = validateAndNormalize(overrides)
                    logSummary(origin: explicit, overrides: validated, warnings: warnings)
                    return validated
                } else {
                    log("Config: explicit path set but not readable (\(explicit))")
                }
            } else {
                log("Config: explicit path set but not readable (\(explicit))")
            }
            return ConfigFileOverrides()
        }
        let xdgBase: URL = {
            if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { return URL(fileURLWithPath: xdg, isDirectory: true) }
            return fm.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }()
        let path = xdgBase.appendingPathComponent("daily-shutdown", isDirectory: true).appendingPathComponent("config.toml")
        guard let data = try? Data(contentsOf: path) else {
            log("Config: no config file found at \(path.path)")
            return ConfigFileOverrides()
        }
        if data.count > maxConfigBytes {
            log("Config: file exceeds size cap (\(data.count) > \(maxConfigBytes)) ignoring")
            return ConfigFileOverrides()
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            log("Config: could not decode file as UTF-8 at \(path.path)")
            return ConfigFileOverrides()
        }
        let overrides = parseToml(raw)
        let (validated, warnings) = validateAndNormalize(overrides)
        logSummary(origin: path.path, overrides: validated, warnings: warnings)
        return validated
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
        let model: FileConfigDecodable
        do {
            model = try decoder.decode(FileConfigDecodable.self, from: toml)
        } catch {
            log("Config: TOML decode failed: \(error)")
            return ConfigFileOverrides()
        }
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

    // MARK: - Validation & Normalization
    private static func validateAndNormalize(_ o: ConfigFileOverrides) -> (ConfigFileOverrides, [String]) {
        var v = o
        var warnings: [String] = []

        func rangeCheck(_ value: Int?, name: String, range: ClosedRange<Int>) -> Int? {
            guard let value = value else { return nil }
            if !range.contains(value) {
                warnings.append("\(name) out of range: \(value)")
                return nil
            }
            return value
        }
        v.dailyHour = rangeCheck(v.dailyHour, name: "dailyHour", range: 0...23)
        v.dailyMinute = rangeCheck(v.dailyMinute, name: "dailyMinute", range: 0...59)

        if let p = v.defaultPostponeIntervalSeconds, p <= 0 {
            warnings.append("defaultPostponeIntervalSeconds must be > 0 (was \(p))")
            v.defaultPostponeIntervalSeconds = nil
        }
        if let p = v.postponeIntervalSeconds, p <= 0 {
            warnings.append("postponeIntervalSeconds must be > 0 (was \(p))")
            v.postponeIntervalSeconds = nil
        }
        if let m = v.defaultMaxPostpones, m < 0 {
            warnings.append("defaultMaxPostpones must be >= 0 (was \(m))")
            v.defaultMaxPostpones = nil
        }
        if let m = v.maxPostpones, m < 0 {
            warnings.append("maxPostpones must be >= 0 (was \(m))")
            v.maxPostpones = nil
        }
        if let rel = v.relativeSeconds, rel <= 0 {
            warnings.append("relativeSeconds must be > 0 (was \(rel))")
            v.relativeSeconds = nil
        }

        func normalizeOffsets(_ arr: [Int]?) -> [Int]? {
            guard let arr = arr else { return nil }
            let filtered = Array(Set(arr.filter { $0 > 0 })).sorted(by: >)
            if filtered.isEmpty { return nil }
            return filtered
        }
        let normalizedDefaults = normalizeOffsets(v.defaultWarningOffsets)
        if v.defaultWarningOffsets != normalizedDefaults { warnings.append("defaultWarningOffsets normalized/deduped") }
        v.defaultWarningOffsets = normalizedDefaults
        let normalizedWarn = normalizeOffsets(v.warnOffsets)
        if v.warnOffsets != normalizedWarn { warnings.append("warnOffsets normalized/deduped") }
        v.warnOffsets = normalizedWarn

        return (v, warnings)
    }

    private static func logSummary(origin: String, overrides: ConfigFileOverrides, warnings: [String]) {
        var setKeys: [String] = []
        if overrides.dailyHour != nil { setKeys.append("dailyHour") }
        if overrides.dailyMinute != nil { setKeys.append("dailyMinute") }
        if overrides.defaultPostponeIntervalSeconds != nil { setKeys.append("defaultPostponeIntervalSeconds") }
        if overrides.defaultMaxPostpones != nil { setKeys.append("defaultMaxPostpones") }
        if overrides.defaultWarningOffsets != nil { setKeys.append("defaultWarningOffsets") }
        if overrides.relativeSeconds != nil { setKeys.append("relativeSeconds") }
        if overrides.warnOffsets != nil { setKeys.append("warnOffsets") }
        if overrides.dryRun != nil { setKeys.append("dryRun") }
        if overrides.noPersist != nil { setKeys.append("noPersist") }
        if overrides.postponeIntervalSeconds != nil { setKeys.append("postponeIntervalSeconds") }
        if overrides.maxPostpones != nil { setKeys.append("maxPostpones") }
        let keysDesc = setKeys.isEmpty ? "(none)" : setKeys.joined(separator: ",")
        log("Config: applied overrides from \(origin) keys=[\(keysDesc)] warnings=\(warnings.count)")
        for w in warnings { log("Config warning: \(w)") }
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
