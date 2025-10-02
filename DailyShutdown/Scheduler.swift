import Foundation

/// Delegate notified when timers for warning or final shutdown fire.
public protocol SchedulerDelegate: AnyObject {
    func warningDue()
    func shutdownDue()
}

/// Schedules dispatch timers for warning & shutdown events. Owns its private queue.
public final class Scheduler {
    public weak var delegate: SchedulerDelegate?
    private var warningTimer: DispatchSourceTimer?
    private var finalTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "scheduler.queue", qos: .userInitiated)

    public init() {}

    /// Schedule (replacing any existing timers) a shutdown at `shutdownDate` and optional warning.
    /// Intervals are clamped to zero (fire immediately) if already elapsed.
    public func schedule(shutdownDate: Date, warningDate: Date?) {
        cancel()
        let now = Date()
        let finalInterval = max(0, shutdownDate.timeIntervalSince(now))
        let final = DispatchSource.makeTimerSource(queue: queue)
        final.schedule(deadline: .now() + finalInterval)
        final.setEventHandler { [weak self] in self?.delegate?.shutdownDue() }
        finalTimer = final
        final.activate()
        if let w = warningDate {
            let warningInterval = max(0, w.timeIntervalSince(now))
            let warn = DispatchSource.makeTimerSource(queue: queue)
            warn.schedule(deadline: .now() + warningInterval)
            warn.setEventHandler { [weak self] in self?.delegate?.warningDue() }
            warningTimer = warn
            warn.activate()
        }
        log("Scheduler: scheduled shutdown in \(String(format: "%.2f", finalInterval))s warningAt?=\(String(describing: warningDate))")
    }

    /// Cancel any in-flight timers (idempotent).
    public func cancel() {
        warningTimer?.cancel(); warningTimer = nil
        finalTimer?.cancel(); finalTimer = nil
    }
}
