import Foundation

/// Delegate notified when timers for warning or final shutdown fire.
public protocol SchedulerDelegate: AnyObject {
    func warningDue()
    func shutdownDue()
}

/// Schedules dispatch timers for warning & shutdown events. Owns its private queue.
public final class Scheduler {
    public weak var delegate: SchedulerDelegate?
    // Maintain references so timers aren't deallocated.
    private var warningTimers: [CancellableTimer] = []
    private var finalTimer: CancellableTimer?
    private let queue: DispatchQueue
    private let timerFactory: TimerFactory

    public init(queue: DispatchQueue = DispatchQueue(label: "scheduler.queue", qos: .userInitiated),
                timerFactory: TimerFactory = GCDTimerFactory()) {
        self.queue = queue
        self.timerFactory = timerFactory
    }

    /// Schedule (replacing any existing timers) a shutdown at `shutdownDate` and optional warning.
    /// Intervals are clamped to zero (fire immediately) if already elapsed.
    public func schedule(shutdownDate: Date, warningDate: Date?, warningOffsets: [Int] = []) {
        cancel()

        // Capture a single reference time so both intervals are derived consistently.
        let now = Date()
        // Seconds until shutdown (never negative).
        let finalInterval = max(0, shutdownDate.timeIntervalSince(now)) // seconds

        // Final shutdown timer.
        finalTimer = timerFactory.scheduleSingle(after: finalInterval, queue: queue) { [weak self] in
            self?.delegate?.shutdownDue()
        }

        // Compute staged warning thresholds (seconds before shutdown) relative to final shutdown.
        let thresholds: [TimeInterval] = warningOffsets.map { TimeInterval($0) }
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
            let timer = timerFactory.scheduleSingle(after: interval, queue: queue) { [weak self] in
                self?.delegate?.warningDue()
            }
            warningTimers.append(timer)
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

// MARK: - Timer Abstractions
/// Token that allows cancellation of a scheduled timer.
public protocol CancellableTimer { func cancel() }

/// Factory abstraction to create timers; aids deterministic testing.
public protocol TimerFactory {
    func scheduleSingle(after interval: TimeInterval, queue: DispatchQueue, handler: @escaping () -> Void) -> CancellableTimer
}

/// Production implementation backed by DispatchSourceTimer.
public final class GCDTimerFactory: TimerFactory {
    public init() {}
    private final class Token: CancellableTimer {
        private let timer: DispatchSourceTimer
        init(timer: DispatchSourceTimer) { self.timer = timer }
        func cancel() { timer.cancel() }
    }
    public func scheduleSingle(after interval: TimeInterval, queue: DispatchQueue, handler: @escaping () -> Void) -> CancellableTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval)
        t.setEventHandler(handler: handler)
        t.activate()
        return Token(timer: t)
    }
}
