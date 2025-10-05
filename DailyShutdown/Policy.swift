import Foundation

/// Result of evaluating a scheduling policy for the current state.
/// - shutdownDate: The definitive time the system should shut down.
/// - warningDate: Optional primary warning time (may be nil). Additional staged warnings
///   (e.g., 15m/5m/1m) are derived by the Scheduler to preserve Open/Closed segregation.
struct SchedulePlan: Equatable {
    let shutdownDate: Date
    let warningDate: Date?
}

/// Abstraction describing pure scheduling & postponement rules.
protocol ShutdownPolicyType {
    /// Compute a schedule plan for the provided state at `now`. Returns nil if state is invalid.
    func plan(for state: ShutdownState, config: AppConfig, now: Date) -> SchedulePlan?
    /// Whether the user can still postpone given current usage and config limits.
    func canPostpone(state: ShutdownState, config: AppConfig) -> Bool
    /// Mutate state to reflect a postpone action (adjust time & increment usage).
    func applyPostpone(state: inout ShutdownState, config: AppConfig, now: Date)
}

final class ShutdownPolicy: ShutdownPolicyType {
    init() {}

    /// Determine the actual shutdown and (optional) warning times based on state & config.
    /// If the warning time would be in the past, it is clamped to `now` (immediate presentation).
    func plan(for state: ShutdownState, config: AppConfig, now: Date) -> SchedulePlan? {
        guard let shutdownDate = StateFactory.parseISO(state.scheduledShutdownISO) else { return nil }
        var warning: Date? = nil
        if canPostpone(state: state, config: config), let lead = config.primaryWarningLeadSeconds {
            let candidate = shutdownDate.addingTimeInterval(-TimeInterval(lead))
            warning = candidate > now ? candidate : now // immediate if already passed
        }
        return SchedulePlan(shutdownDate: shutdownDate, warningDate: warning)
    }

    /// A postpone is permitted if used count is below the configured maximum.
    func canPostpone(state: ShutdownState, config: AppConfig) -> Bool {
        state.postponesUsed < config.effectiveMaxPostpones
    }

    /// Shift scheduled shutdown by one postpone interval and increment usage counter.
    func applyPostpone(state: inout ShutdownState, config: AppConfig, now: Date) {
        guard let date = StateFactory.parseISO(state.scheduledShutdownISO) else { return }
        let newDate = date.addingTimeInterval(TimeInterval(config.effectivePostponeIntervalSeconds))
        state.postponesUsed += 1
        state.scheduledShutdownISO = StateFactory.isoDate(newDate)
    }
}
