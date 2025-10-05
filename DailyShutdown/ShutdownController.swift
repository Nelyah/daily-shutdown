import Foundation
import AppKit

    /// Original scheduled shutdown ISO string for the cycle during which the currently active alert
    /// was presented. Used to detect when a cycle rollover occurs while an alert is still visible
    /// so that, upon dismissal, warnings for the new cycle can be (re)sheduled.
    private var activeAlertCycleOriginalISO: String? = nil
/// Orchestrates the full shutdown cycle: loading/creating state, computing policy plans,
/// scheduling timers, presenting alerts, handling user actions, and initiating system shutdown.
/// Thread-safety: state mutations are serialized via `stateQueue`.
public final class ShutdownController: SchedulerDelegate, AlertPresenterDelegate {
    private let config: AppConfig
    /// Once a warning has been presented in the current cycle, additional scheduled warnings
    /// (from smaller offsets) are suppressed to avoid multiple sequential popups. This flag
    /// is cleared when the user postpones (creating a materially new schedule) or when a 
    /// cycle rollover occurs (post-shutdown or dry-run). Dismissing or ignoring the alert
    /// does NOT clear this flag, ensuring only a single warning per cycle unless the user
    /// takes an action that alters the schedule.
    private var warningPresentedThisCycle: Bool = false
    private let stateStore: StateStore
    private var state: ShutdownState
    private let clock: Clock
    private let policy: ShutdownPolicyType
    private let scheduler: Scheduler
    private let actions: SystemActions
    private let alertPresenter: AlertPresenting
    private let stateQueue = DispatchQueue(label: "shutdown.controller.state", qos: .userInitiated)

    private let workDir: URL

    /// True while a warning alert window is currently presented to the user.
    /// Invariant: set to true immediately before invoking `alertPresenter.present(model:)` and
    /// reset to false upon any delegate callback (postpone / shutdown / ignore) or when a
    /// shutdown cycle rolls over. Prevents multiple overlapping warning windows.
    private var warningAlertActive: Bool = false

    /// Create a controller with injected agents; defaults are provided for production runtime.
    /// State is initialized immediately (and persisted unless `--no-persist`). Delegates are then wired.
    public init(config: AppConfig,
                stateStore: StateStore? = nil,
                clock: Clock = SystemClock(),
                policy: ShutdownPolicyType = ShutdownPolicy(),
                scheduler: Scheduler = Scheduler(),
                actions: SystemActions = AppleScriptSystemActions(),
                alertPresenter: AlertPresenting? = nil) {
        self.config = config
        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DailyShutdown", isDirectory: true)
        self.workDir = baseDir
        self.stateStore = stateStore ?? FileStateStore(directory: baseDir)
        self.clock = clock
        self.policy = policy
        self.scheduler = scheduler
        self.actions = actions
        let presenter = alertPresenter ?? AlertPresenter()
        self.alertPresenter = presenter
      
      		// Initialize state BEFORE assigning delegates because delegate properties capture self.
      		// Swift requires all stored properties to be initialized prior to using self.
      		let now = clock.now()
      		self.state = StateFactory.newState(now: now, config: config)
      		if !config.options.noPersist { self.stateStore.save(self.state) }
      
      		// Now safe to assign delegates
      		presenter.delegate = self
      		scheduler.delegate = self
    }

    /// Begin scheduling according to current state and log startup information.
    public func start() {
        reschedule()
        logStartup()
    }

    /// Recompute plan & schedule timers (executed on `stateQueue`).
    private func reschedule() {
        stateQueue.async { [self] in
            let now = clock.now()
            guard let plan = policy.plan(for: state, config: config, now: now) else { return }
            scheduler.schedule(
                shutdownDate: plan.shutdownDate,
                warningDate: plan.warningDate,
                warningOffsets: config.effectiveWarningOffsets
            )
        }
    }

    /// Emit initial schedule log for observability.
    private func logStartup() {
        if let date = StateFactory.parseISO(state.scheduledShutdownISO) {
            let df = DateFormatter(); df.timeStyle = .short; df.timeZone = .current
            log("Scheduled shutdown (local) at \(df.string(from: date))")
        }
    }

    // MARK: SchedulerDelegate
    /// Warning timer fired: present alert with current model details.
    public func warningDue() {
        stateQueue.async { [self] in
            // Suppress if an alert is active or we already showed a warning this cycle.
            if warningAlertActive || warningPresentedThisCycle { return }
            guard let shutdownDate = StateFactory.parseISO(state.scheduledShutdownISO),
                  let originalDate = StateFactory.parseISO(state.originalScheduledShutdownISO) else { return }
            let model = AlertModel(
                scheduled: shutdownDate,
                original: originalDate,
                postponesUsed: state.postponesUsed,
                maxPostpones: config.effectiveMaxPostpones,
                postponeIntervalMinutes: Int(round(Double(config.effectivePostponeIntervalSeconds)/60.0))
            )
            warningAlertActive = true
            warningPresentedThisCycle = true
            activeAlertCycleOriginalISO = state.originalScheduledShutdownISO
            alertPresenter.present(model: model)
        }
    }

    /// Final shutdown timer fired: initiate shutdown sequence.
    public func shutdownDue() {
        performShutdown()
    }

    // MARK: AlertPresenterDelegate
    /// User requested a postpone: validate with policy then mutate state & reschedule.
    public func userChosePostpone() {
        stateQueue.async { [self] in
            warningAlertActive = false
            // Allow a new warning for the newly postponed schedule.
            warningPresentedThisCycle = false
            activeAlertCycleOriginalISO = nil
            guard policy.canPostpone(state: state, config: config) else { return }
            policy.applyPostpone(state: &state, config: config, now: clock.now())
            if !config.options.noPersist { stateStore.save(state) }
            log("Postponed: new time = \(state.scheduledShutdownISO) uses=\(state.postponesUsed)/\(config.effectiveMaxPostpones)")
            reschedule()
        }
    }

    /// User chose immediate shutdown.
    public func userChoseShutdownNow() { performShutdown() }
    /// User dismissed/ignored the alert; simply clear the active flag so future warnings can display.
    public func userIgnored() {
        stateQueue.async { [self] in
            warningAlertActive = false
            // Intentionally keep warningPresentedThisCycle = true to suppress further alerts.
            // If the cycle rolled over while the alert was open, re-enable warning for the new cycle.
            if let presentedCycle = activeAlertCycleOriginalISO, presentedCycle != state.originalScheduledShutdownISO {
                warningPresentedThisCycle = false
                activeAlertCycleOriginalISO = nil
                reschedule() // schedule warnings for the new cycle now that UI is clear
            } else {
                activeAlertCycleOriginalISO = nil
            }
        }
    }

    /// Perform (or simulate) system shutdown, roll state into next cycle, and schedule again.
    private func performShutdown() {
        stateQueue.async { [self] in
            // Reset any active alert state before rolling over.
            // Do NOT clear warningAlertActive here if an alert is being displayed; keep it until
            // user closes it to prevent overlapping alerts across cycle boundary. We still reset
            // the per-cycle flag so that after dismissal a new warning can be shown for the new cycle.
            warningPresentedThisCycle = false
            log("Initiating shutdown dryRun=\(config.options.dryRun)")
            if config.options.dryRun {
                // Roll over to next day for demonstration
                state = StateFactory.newState(now: clock.now(), config: config)
                // Defer scheduling warnings until any existing alert is dismissed (if active).
                if !warningAlertActive { reschedule() }
                if !config.options.noPersist { stateStore.save(state) }
                return
            }
            actions.shutdown()
            // Schedule next cycle optimistically
            state = StateFactory.newState(now: clock.now(), config: config)
            if !config.options.noPersist { stateStore.save(state) }
            if !warningAlertActive { reschedule() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
    }

#if DEBUG
    /// Test-only helper: asynchronously provide the current in-memory state snapshot.
    public func _testCurrentState(completion: @escaping (ShutdownState) -> Void) {
        stateQueue.async { completion(self.state) }
    }
#endif
}
