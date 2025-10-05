import Foundation

/// Persistent model capturing a single shutdown cycle's scheduling information.
/// - date: Calendar day (yyyy-MM-dd) representing the cycle start.
/// - postponesUsed: Number of user postponements consumed.
/// - scheduledShutdownISO: Current effective shutdown time (ISO8601 with fractional seconds).
/// - originalScheduledShutdownISO: Immutable original scheduled shutdown time for reference.
struct ShutdownState: Codable, Equatable {
    var date: String          // yyyy-MM-dd for cycle
    var postponesUsed: Int
    var scheduledShutdownISO: String
    var originalScheduledShutdownISO: String
}

/// Abstraction over persistence of `ShutdownState` allowing different backends (file, memory, network).
protocol StateStore {
    func load() -> ShutdownState?
    func save(_ state: ShutdownState)
}

final class FileStateStore: StateStore {
    private let fileURL: URL
    private let fm = FileManager.default
    init(directory: URL) {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("state.json")
    }
    /// Load the most recently saved state from disk; returns nil if missing or decode fails.
    func load() -> ShutdownState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ShutdownState.self, from: data)
    }
    /// Persist the given state atomically to disk. Errors are ignored (best-effort).
    func save(_ state: ShutdownState) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Time source abstraction to enable deterministic tests via injected clocks.
protocol Clock {
    func now() -> Date
}
struct SystemClock: Clock {
    // Explicit public initializer so it can be used as a default parameter in
    // public initializers elsewhere.
    init() {}
    /// Returns the current wall-clock date/time (`Date()`).
    func now() -> Date { Date() }
}

enum StateFactory {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create a new `ShutdownState` from scratch given the current `now` and effective configuration.
    /// If `--in-seconds` was specified the shutdown time is relative. Otherwise the next configured
    /// daily hour/minute (today or tomorrow if already passed) is chosen.
    static func newState(now: Date, config: AppConfig) -> ShutdownState {
        if let rel = config.options.relativeSeconds {
            let shutdownDate = now.addingTimeInterval(TimeInterval(rel))
            return ShutdownState(
                date: dayFormatter.string(from: now),
                postponesUsed: 0,
                scheduledShutdownISO: isoFormatter.string(from: shutdownDate),
                originalScheduledShutdownISO: isoFormatter.string(from: shutdownDate)
            )
        }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = config.dailyHour
        comps.minute = config.dailyMinute
        comps.second = 0
        var shutdownDate = Calendar.current.date(from: comps) ?? now
        if shutdownDate <= now { shutdownDate = Calendar.current.date(byAdding: .day, value: 1, to: shutdownDate) ?? shutdownDate }
        return ShutdownState(
            date: dayFormatter.string(from: now),
            postponesUsed: 0,
            scheduledShutdownISO: isoFormatter.string(from: shutdownDate),
            originalScheduledShutdownISO: isoFormatter.string(from: shutdownDate)
        )
    }

    /// Format a `Date` into the canonical ISO8601 representation used in persisted state.
    static func isoDate(_ date: Date) -> String { isoFormatter.string(from: date) }
    /// Parse a stored ISO8601 timestamp back into a `Date`.
    static func parseISO(_ iso: String) -> Date? { isoFormatter.date(from: iso) }
}
