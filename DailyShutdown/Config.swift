import Foundation

/// User-supplied runtime flags parsed from the command line. All values are optional;
/// unset values fall back to defaults contained in `AppConfig`.
public struct RuntimeOptions: Equatable {
    public var relativeSeconds: Int? = nil      // --in-seconds N
    public var warnLeadSeconds: Int? = nil      // --warn-seconds S
    public var dryRun = false                   // --dry-run
    public var noPersist = false                // --no-persist
    public var postponeIntervalSeconds: Int? = nil // --postpone-sec S
    public var maxPostpones: Int? = nil         // --max-postpones K
}

/// Immutable application configuration composed of defaults and `RuntimeOptions` overrides.
/// This is injected into all agents needing policy / scheduling parameters.
public struct AppConfig: Equatable {
    public let dailyHour: Int
    public let dailyMinute: Int
    public let defaultWarningLeadSeconds: Int
    public let defaultPostponeIntervalSeconds: Int
    public let defaultMaxPostpones: Int
    public let options: RuntimeOptions

    /// Effective warning lead time in seconds, using runtime override if present.
    public var effectiveWarningLeadSeconds: Int {
        options.warnLeadSeconds ?? defaultWarningLeadSeconds
    }
    /// Effective postpone interval (seconds), using runtime override if present.
    public var effectivePostponeIntervalSeconds: Int {
        options.postponeIntervalSeconds ?? defaultPostponeIntervalSeconds
    }
    /// Effective maximum number of postpones allowed in a shutdown cycle.
    public var effectiveMaxPostpones: Int {
        options.maxPostpones ?? defaultMaxPostpones
    }
}

public enum CommandLineConfigParser {
    /// Parse command line `arguments` (defaults to `CommandLine.arguments`) into an `AppConfig`.
    /// Unspecified flags retain their default values. Unknown flags are ignored.
    public static func parse(arguments: [String] = CommandLine.arguments) -> AppConfig {
        var opts = RuntimeOptions()
        var it = arguments.makeIterator()
        _ = it.next() // skip exe
        while let a = it.next() {
            switch a {
            case "--in-seconds":
                if let v = it.next(), let s = Int(v) { opts.relativeSeconds = s }
            case "--warn-seconds":
                if let v = it.next(), let s = Int(v) { opts.warnLeadSeconds = s }
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
            defaultWarningLeadSeconds: 15 * 60,
            defaultPostponeIntervalSeconds: 15 * 60,
            defaultMaxPostpones: 3,
            options: opts
        )
    }
}
