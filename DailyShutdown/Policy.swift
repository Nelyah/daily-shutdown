import Foundation

public struct SchedulePlan: Equatable {
    public let shutdownDate: Date
    public let warningDate: Date?
}

public protocol ShutdownPolicyType {
    func plan(for state: ShutdownState, config: AppConfig, now: Date) -> SchedulePlan?
    func canPostpone(state: ShutdownState, config: AppConfig) -> Bool
    func applyPostpone(state: inout ShutdownState, config: AppConfig, now: Date)
}

public final class ShutdownPolicy: ShutdownPolicyType {
    public init() {}

    public func plan(for state: ShutdownState, config: AppConfig, now: Date) -> SchedulePlan? {
        guard let shutdownDate = StateFactory.parseISO(state.scheduledShutdownISO) else { return nil }
        let warningLead = TimeInterval(config.effectiveWarningLeadSeconds)
        var warning: Date? = nil
        if canPostpone(state: state, config: config) {
            let candidate = shutdownDate.addingTimeInterval(-warningLead)
            if candidate > now { warning = candidate } else { warning = now } // present immediately if passed
        }
        return SchedulePlan(shutdownDate: shutdownDate, warningDate: warning)
    }

    public func canPostpone(state: ShutdownState, config: AppConfig) -> Bool {
        state.postponesUsed < config.effectiveMaxPostpones
    }

    public func applyPostpone(state: inout ShutdownState, config: AppConfig, now: Date) {
        guard let date = StateFactory.parseISO(state.scheduledShutdownISO) else { return }
        let newDate = date.addingTimeInterval(TimeInterval(config.effectivePostponeIntervalSeconds))
        state.postponesUsed += 1
        state.scheduledShutdownISO = StateFactory.isoDate(newDate)
    }
}
