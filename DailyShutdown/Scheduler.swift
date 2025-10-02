import Foundation

/// Delegate notified when timers for warning or final shutdown fire.
public protocol SchedulerDelegate: AnyObject {
    func warningDue()
    func shutdownDue()
}

/// Schedules dispatch timers for warning & shutdown events. Owns its private queue.
public final class Scheduler {
    public weak var delegate: SchedulerDelegate?
    // Multiple warning timers (15m, 5m, 1m) before final shutdown.
    private var warningTimers: [DispatchSourceTimer] = []
    private var finalTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "scheduler.queue", qos: .userInitiated)

    public init() {}

    /// Schedule (replacing any existing timers) a shutdown at `shutdownDate` and optional warning.
    /// Intervals are clamped to zero (fire immediately) if already elapsed.
    public func schedule(shutdownDate: Date, warningDate: Date?) {
        cancel()

        // Capture a single reference time so both intervals are derived consistently.
        let now = Date()
        // Seconds until shutdown (never negative).
        let finalInterval = max(0, shutdownDate.timeIntervalSince(now)) // seconds

        // Final shutdown timer.
        let final = DispatchSource.makeTimerSource(queue: queue)
        final.schedule(deadline: .now() + finalInterval)
        final.setEventHandler { [weak self] in self?.delegate?.shutdownDue() }
        finalTimer = final
        final.activate()

        // Compute desired warning thresholds (15m, 5m, 1m) relative to final shutdown.
        let thresholds: [TimeInterval] = [15*60, 5*60, 1*60]
        var plannedWarningDates: [Date] = []
        for t in thresholds {
            let candidate = shutdownDate.addingTimeInterval(-t)
            if candidate > now { plannedWarningDates.append(candidate) }
        }
        // Include provided explicit warningDate if present (legacy policy output) and still future.
        if let explicit = warningDate, explicit > now, !plannedWarningDates.contains(where: { abs($0.timeIntervalSince(explicit)) < 0.5 }) {
            plannedWarningDates.append(explicit)
        }
        // Sort ascending to fire earliest first.
        plannedWarningDates.sort()
        // Create timers for each planned warning date.
        for wd in plannedWarningDates {
            let interval = max(0, wd.timeIntervalSince(now))
            let warn = DispatchSource.makeTimerSource(queue: queue)
            warn.schedule(deadline: .now() + interval)
            warn.setEventHandler { [weak self] in self?.delegate?.warningDue() }
            warningTimers.append(warn)
            warn.activate()
        }

        // Log with explicit ISO8601 timestamp of final shutdown and optional warning.
        let iso = ISO8601DateFormatter()
        let finalISO = iso.string(from: shutdownDate)
        let warningList = plannedWarningDates.map { iso.string(from: $0) }.joined(separator: ", ")
        log("Scheduler: finalDate=\(finalISO) in=\(String(format: "%.2f", finalInterval))s warnings=[\(warningList)]")
    }

    /// Cancel any in-flight timers (idempotent).
    public func cancel() {
        warningTimers.forEach { $0.cancel() }
        warningTimers.removeAll()
        finalTimer?.cancel(); finalTimer = nil
    }
}
