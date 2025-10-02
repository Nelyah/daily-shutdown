import Foundation

public struct RuntimeOptions: Equatable {
    public var relativeSeconds: Int? = nil      // --in-seconds N
    public var warnLeadSeconds: Int? = nil      // --warn-seconds S
    public var dryRun = false                   // --dry-run
    public var noPersist = false                // --no-persist
    public var postponeIntervalSeconds: Int? = nil // --postpone-sec S
    public var maxPostpones: Int? = nil         // --max-postpones K
}

public struct AppConfig: Equatable {
    public let dailyHour: Int
    public let dailyMinute: Int
    public let defaultWarningLeadSeconds: Int
    public let defaultPostponeIntervalSeconds: Int
    public let defaultMaxPostpones: Int
    public let options: RuntimeOptions

    public var effectiveWarningLeadSeconds: Int {
        options.warnLeadSeconds ?? defaultWarningLeadSeconds
    }
    public var effectivePostponeIntervalSeconds: Int {
        options.postponeIntervalSeconds ?? defaultPostponeIntervalSeconds
    }
    public var effectiveMaxPostpones: Int {
        options.maxPostpones ?? defaultMaxPostpones
    }
}

public enum CommandLineConfigParser {
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
