import Foundation

/// Configuration root for reminder subsystem parsed from TOML (future implementation).
/// Currently scaffolded; parsing not yet wired.
struct ReminderConfig: Equatable {
    struct Item: Equatable {
        let id: String
        let startHour: Int
        let startMinute: Int
        let intervalSeconds: Int
        let prompt: String
        let requiredText: String
        let caseInsensitive: Bool
    }
    let items: [Item]
}

// MARK: - Parsing

struct ReminderConfigParseResult {
    let config: ReminderConfig
    let warnings: [String]
    let errors: [String]
}

/// Parse a reminders TOML fragment (already extracted) into a sanitized ReminderConfig.
/// Expected shape:
/// [reminders]
/// [[reminders.items]]
/// id = "..."
/// startTime = "HH:MM"
/// intervalSeconds = 300
/// prompt = "..."
/// requiredText = "..."
/// caseInsensitive = true
/// Unknown keys ignored. Errors (missing required fields) drop that item. Non-fatal issues become warnings
/// with automatic normalization (e.g., interval clamped to minimum).
internal func parseReminderConfig(from toml: String) -> ReminderConfigParseResult {
    // Minimal ad-hoc parse (future: adopt TOMLDecoder mapping into a decodable struct).
    // Strategy: identify sections beginning with '[[reminders.items]]', collect key=val pairs until next section.
    enum FieldKey: String { case id, startTime, intervalSeconds, prompt, requiredText, caseInsensitive }
    var items: [ReminderConfig.Item] = []
    var warnings: [String] = []
    var errors: [String] = []

    let lines = toml.split(separator: "\n", omittingEmptySubsequences: false)
    var current: [String:String] = [:]
    func flushCurrent() {
        guard !current.isEmpty else { return }
        // Extract & validate
        let id = current[FieldKey.id.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let startTime = current[FieldKey.startTime.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let intervalStr = current[FieldKey.intervalSeconds.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = current[FieldKey.prompt.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requiredText = current[FieldKey.requiredText.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ciStr = current[FieldKey.caseInsensitive.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if id.isEmpty { errors.append("item missing id"); current.removeAll(); return }
        // startTime HH:MM
        let timeParts = startTime.split(separator: ":")
        var startHour: Int = 0, startMinute: Int = 0
        if timeParts.count == 2, let h = Int(timeParts[0]), let m = Int(timeParts[1]), (0...23).contains(h), (0...59).contains(m) {
            startHour = h; startMinute = m
        } else {
            errors.append("reminder id=\(id) invalid startTime=\(startTime)")
            current.removeAll(); return
        }
        guard let intervalRaw = intervalStr, let intervalVal = Int(intervalRaw) else { errors.append("reminder id=\(id) missing intervalSeconds"); current.removeAll(); return }
        var interval = intervalVal
        if interval < 30 { warnings.append("reminder id=\(id) intervalSeconds<30 clamped"); interval = 30 }
        if interval > 86400 { warnings.append("reminder id=\(id) intervalSeconds>86400 clamped"); interval = 86400 }
        if prompt.isEmpty { errors.append("reminder id=\(id) missing prompt"); current.removeAll(); return }
        if requiredText.isEmpty { errors.append("reminder id=\(id) missing requiredText"); current.removeAll(); return }
        let caseInsensitive: Bool = {
            guard let s = ciStr?.lowercased() else { return true }
            if ["true", "false"].contains(s) { return s == "true" }
            warnings.append("reminder id=\(id) invalid caseInsensitive=\(s) default true")
            return true
        }()
        items.append(.init(id: id, startHour: startHour, startMinute: startMinute, intervalSeconds: interval, prompt: prompt, requiredText: requiredText, caseInsensitive: caseInsensitive))
        current.removeAll()
    }
    var inItemsSection = false
    for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") || line.isEmpty { continue }
        if line == "[[reminders.items]]" {
            inItemsSection = true
            flushCurrent() // flush previous before starting new (ensures isolated blocks)
            continue
        }
        guard inItemsSection else { continue }
        // key = value (string or number or bool)
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count != 2 { continue }
        let key = parts[0]
        var value = parts[1]
        if value.first == "\"", value.last == "\"" { value = String(value.dropFirst().dropLast()) }
        current[String(key)] = String(value)
    }
    flushCurrent()
    // Deduplicate IDs (keep first)
    var seen: Set<String> = []
    var deduped: [ReminderConfig.Item] = []
    for item in items {
        if seen.contains(item.id) { warnings.append("duplicate reminder id=\(item.id) ignored") } else { seen.insert(item.id); deduped.append(item) }
    }
    return ReminderConfigParseResult(config: ReminderConfig(items: deduped), warnings: warnings, errors: errors)
}

/// Runtime per-day reminder state. Resets at local day boundary.
struct ReminderRuntimeState: Codable, Equatable {
    let date: String                 // yyyy-MM-dd
    var completions: Set<String>     // ids completed today
    var lastFireISO: [String:String] // id -> last fire timestamp ISO
}

/// Persistence abstraction (mirrors StateStore style) allowing alternate backends.
protocol ReminderStateStore {
    func load() -> ReminderRuntimeState?
    func save(_ state: ReminderRuntimeState)
}

/// Pure policy computing next fire time for a single reminder item.
protocol ReminderPolicyType {
    func nextFire(for item: ReminderConfig.Item, state: ReminderRuntimeState, now: Date) -> Date?
}

/// Model provided to UI presenter for a reminder firing.
struct ReminderAlertModel {
    let id: String
    let prompt: String
    let caseInsensitive: Bool
}

/// Presenter delegate capturing user actions.
protocol ReminderPresenterDelegate: AnyObject {
    func reminderUserSubmitted(id: String, text: String)
    func reminderUserIgnored(id: String)
}

/// UI presentation abstraction (parallel to AlertPresenting for shutdown warnings).
protocol ReminderPresenting: AnyObject {
    var delegate: ReminderPresenterDelegate? { get set }
    func present(model: ReminderAlertModel)
}

/// Scheduling abstraction for one-shot reminder timers.
protocol ReminderScheduling: AnyObject {
    func schedule(id: String, at date: Date)
    func cancel(id: String)
    func cancelAll()
}

/// Concrete pure policy implementation.
struct ReminderPolicy: ReminderPolicyType {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    func nextFire(for item: ReminderConfig.Item, state: ReminderRuntimeState, now: Date) -> Date? {
        if state.completions.contains(item.id) { return nil }
        // Compute today's start
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        guard let start = cal.date(bySettingHour: item.startHour, minute: item.startMinute, second: 0, of: now) else { return nil }
        if now < start { return start }
        // Parse last fire if today's state contains one
        let lastISO = state.lastFireISO[item.id]
        var last: Date? = nil
        if let iso = lastISO, let parsed = ReminderPolicy.isoFormatter.date(from: iso) { last = parsed }
        guard let lastDate = last else { return now }
        let candidate = lastDate.addingTimeInterval(TimeInterval(item.intervalSeconds))
        return candidate > now ? candidate : now
    }
}

/// In-memory store (test usage) capturing state without disk IO.
final class InMemoryReminderStateStore: ReminderStateStore {
    private var stored: ReminderRuntimeState?
    init(initial: ReminderRuntimeState? = nil) { self.stored = initial }
    func load() -> ReminderRuntimeState? { stored }
    func save(_ state: ReminderRuntimeState) { stored = state }
}

/// Simple scheduler backed by TimerFactory-like closure for testability.
final class ReminderScheduler: ReminderScheduling {
    private var timers: [String: Timer] = [:]
    private let queue = DispatchQueue(label: "reminder.scheduler.queue")
    func schedule(id: String, at date: Date) {
        queue.async {
            self.cancel(id: id)
            let interval = max(0, date.timeIntervalSinceNow)
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
                // Intentionally empty; controller will be wired later to handle timer firings.
            }
            self.timers[id] = timer
        }
    }
    func cancel(id: String) { queue.async { self.timers[id]?.invalidate(); self.timers.removeValue(forKey: id) } }
    func cancelAll() { queue.async { for (_, t) in self.timers { t.invalidate() }; self.timers.removeAll() } }
}

/// Controller orchestrating reminder lifecycle (scaffold, logic TBD in subsequent implementation steps).
final class ReminderController {
    private let config: ReminderConfig
    private let stateStore: ReminderStateStore
    private let policy: ReminderPolicyType
    private let scheduler: ReminderScheduling
    private let logger: Logger
    private let clock: Clock
    private let persistEnabled: Bool
    private var state: ReminderRuntimeState
    private let queue = DispatchQueue(label: "reminder.controller.queue")

    init(config: ReminderConfig, clock: Clock, policy: ReminderPolicyType, stateStore: ReminderStateStore, scheduler: ReminderScheduling, logger: Logger, persistEnabled: Bool) {
        self.config = config
        self.clock = clock
        self.policy = policy
        self.stateStore = stateStore
        self.scheduler = scheduler
        self.logger = logger
        self.persistEnabled = persistEnabled
        let today = Self.dayString(clock.now())
        if let loaded = stateStore.load(), loaded.date == today {
            self.state = loaded
        } else {
            self.state = ReminderRuntimeState(date: today, completions: [], lastFireISO: [:])
        }
    }

    func start() {
        queue.async { [self] in
            scheduleAll(now: clock.now())
        }
    }

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    private func scheduleAll(now: Date) {
        for item in config.items {
            if let next = policy.nextFire(for: item, state: state, now: now) {
                logger.info("reminder.schedule id=\(item.id) at=\(next)")
                scheduler.schedule(id: item.id, at: next)
            }
        }
    }
}
