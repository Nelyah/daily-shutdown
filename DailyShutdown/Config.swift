import Foundation

/// User-supplied runtime flags parsed from the command line. All values are optional;
/// unset values fall back to defaults contained in `AppConfig`.
struct RuntimeOptions: Equatable {
    var relativeSeconds: Int? = nil      // --in-seconds N
    var warnOffsets: [Int]? = nil        // --warn-offsets "900,300,60" (seconds before shutdown)
    var dryRun = false                   // --dry-run
    var noPersist = false                // --no-persist
    var postponeIntervalSeconds: Int? = nil // --postpone-sec S
    var maxPostpones: Int? = nil         // --max-postpones K
}

/// Immutable application configuration composed of defaults and `RuntimeOptions` overrides.
/// This is injected into all agents needing policy / scheduling parameters.
struct AppConfig: Equatable {
    let dailyHour: Int
    let dailyMinute: Int
    let defaultPostponeIntervalSeconds: Int
    let defaultMaxPostpones: Int
    /// Default warning offsets (seconds before shutdown). Ordered high->low. Example: [900, 300, 60].
    let defaultWarningOffsets: [Int]
    let options: RuntimeOptions

    /// Effective postpone interval (seconds), using runtime override if present.
    var effectivePostponeIntervalSeconds: Int {
        options.postponeIntervalSeconds ?? defaultPostponeIntervalSeconds
    }
    /// Effective maximum number of postpones allowed in a shutdown cycle.
    var effectiveMaxPostpones: Int {
        options.maxPostpones ?? defaultMaxPostpones
    }
    /// Effective warning offsets list (seconds before shutdown). If user supplied overrides, they replace defaults.
    /// Returned sorted descending (largest offset first) and deduplicated.
    var effectiveWarningOffsets: [Int] {
        let source = options.warnOffsets ?? defaultWarningOffsets
        return Array(Set(source.filter { $0 > 0 })).sorted(by: >)
    }
    /// Primary warning lead (largest offset) used by policy for earliest alert; nil if no offsets.
    var primaryWarningLeadSeconds: Int? { effectiveWarningOffsets.first }
}

enum CommandLineConfigParser {
    /// Command line usage / help text enumerating all supported flags.
    static var helpText: String {
        return """
Usage: daily-shutdown [options]

Sub-commands:
  print-default-config   Print a TOML representation of the built-in default configuration to stdout and exit.

Options:
  -h, --help               Show this help text and exit.
  --in-seconds N           Schedule a shutdown N seconds from now (relative one-off mode).
  --warn-offsets "a,b,c"    Comma or space separated list of warning offsets (seconds before shutdown).
                           Example: --warn-offsets "900,300,60" (15m,5m,1m). Order is irrelevant.
  --postpone-sec S         Override default postpone interval (seconds).
  --max-postpones K        Override maximum number of postpones allowed in a cycle.
  --dry-run                Do not actually shut down; simulate cycles and log actions.
  --no-persist             Disable state persistence (state kept only in memory).

Behavior Notes:
  * Offsets are de-duplicated and sorted descending; only future offsets schedule warnings.
  * The largest warning offset drives the primary warning consideration in policy.
  * Postponing extends the current scheduled shutdown by the effective postpone interval.

Examples:
  daily-shutdown --in-seconds 3600 --warn-offsets "900,300,60"
  daily-shutdown --postpone-sec 600 --max-postpones 4
  daily-shutdown --dry-run --no-persist
  daily-shutdown print-default-config > ~/.config/daily-shutdown/config.toml
"""
    }
    /// Parse command line `arguments` (defaults to `CommandLine.arguments`) into an `AppConfig`.
    /// Unspecified flags retain their default values. Unknown flags are ignored.
    static func parse(arguments: [String] = CommandLine.arguments) -> AppConfig {
        var opts = RuntimeOptions()
        var it = arguments.makeIterator()
        _ = it.next() // skip exe
        while let a = it.next() {
            switch a {
            case "--help", "-h":
                // Help flag is handled in main before calling parse(); ignore here to simplify parsing path.
                continue
            case "print-default-config":
                // Sub-command handled in main before parse is called; ignore here if reached.
                continue
            case "--in-seconds":
                if let v = it.next(), let s = Int(v) { opts.relativeSeconds = s }
            case "--warn-offsets":
                if let v = it.next() {
                    let parts = v.split{ $0 == "," || $0 == " " }.compactMap { Int($0) }
                    if !parts.isEmpty { opts.warnOffsets = parts }
                }
            case "--dry-run":
                opts.dryRun = true
            case "--no-persist":
                opts.noPersist = true
            case "--postpone-sec":
                if let v = it.next(), let s = Int(v) { opts.postponeIntervalSeconds = s }
            case "--max-postpones":
                if let v = it.next(), let s = Int(v) { opts.maxPostpones = s }
            default:
                break
            }
        }
        return AppConfig(
            dailyHour: 18,
            dailyMinute: 0,
            defaultPostponeIntervalSeconds: 15 * 60,
            defaultMaxPostpones: 3,
            defaultWarningOffsets: [15*60, 5*60, 60],
            options: opts
        )
    }
}

extension CommandLineConfigParser {
    /// Produce a TOML string representing the built-in default configuration values.
    /// This excludes any user / file / CLI overrides and is suitable for redirection into
    /// a config file the user can edit.
    static func defaultConfigTOML() -> String {
        let defaults = AppConfig(
            dailyHour: 18,
            dailyMinute: 0,
            defaultPostponeIntervalSeconds: 15 * 60,
            defaultMaxPostpones: 3,
            defaultWarningOffsets: [15*60, 5*60, 60],
            options: RuntimeOptions()
        )
        let offsets = defaults.defaultWarningOffsets.map(String.init).joined(separator: ", ")
        return """
# Default DailyShutdown configuration (TOML)
# Generated at: \(Date())
# Adjust values as needed; CLI flags still override file settings.

dailyHour = \(defaults.dailyHour)
dailyMinute = \(defaults.dailyMinute)
defaultPostponeIntervalSeconds = \(defaults.defaultPostponeIntervalSeconds)
defaultMaxPostpones = \(defaults.defaultMaxPostpones)
defaultWarningOffsets = [\(offsets)]
"""
    }
}
