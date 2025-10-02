import Foundation

public struct ShutdownState: Codable, Equatable {
    public var date: String          // yyyy-MM-dd for cycle
    public var postponesUsed: Int
    public var scheduledShutdownISO: String
    public var originalScheduledShutdownISO: String
}

public protocol StateStore {
    func load() -> ShutdownState?
    func save(_ state: ShutdownState)
}

public final class FileStateStore: StateStore {
    private let fileURL: URL
    private let fm = FileManager.default
    public init(directory: URL) {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("state.json")
    }
    public func load() -> ShutdownState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ShutdownState.self, from: data)
    }
    public func save(_ state: ShutdownState) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

public protocol Clock {
    func now() -> Date
}
public struct SystemClock: Clock {
    // Explicit public initializer so it can be used as a default parameter in
    // public initializers elsewhere.
    public init() {}
    public func now() -> Date { Date() }
}

public enum StateFactory {
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

    public static func newState(now: Date, config: AppConfig) -> ShutdownState {
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

    public static func isoDate(_ date: Date) -> String { isoFormatter.string(from: date) }
    public static func parseISO(_ iso: String) -> Date? { isoFormatter.date(from: iso) }
}
