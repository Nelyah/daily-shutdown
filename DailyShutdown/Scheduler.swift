import Foundation

public protocol SchedulerDelegate: AnyObject {
    func warningDue()
    func shutdownDue()
}

public final class Scheduler {
    public weak var delegate: SchedulerDelegate?
    private var warningTimer: DispatchSourceTimer?
    private var finalTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "scheduler.queue", qos: .userInitiated)

    public init() {}

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

    public func cancel() {
        warningTimer?.cancel(); warningTimer = nil
        finalTimer?.cancel(); finalTimer = nil
    }
}
