import Foundation
import AppKit

    /// Original scheduled shutdown ISO string for the cycle during which the currently active alert
    /// was presented. Used to detect when a cycle rollover occurs while an alert is still visible
    /// so that, upon dismissal, warnings for the new cycle can be (re)sheduled.
    private var activeAlertCycleOriginalISO: String? = nil
/// Orchestrates the full shutdown cycle: loading/creating state, computing policy plans,
/// scheduling timers, presenting alerts, handling user actions, and initiating system shutdown.
/// Thread-safety: state mutations are serialized via `stateQueue`.
final class ShutdownController: SchedulerDelegate, AlertPresenterDelegate {
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

    /// The last shutdown `Date` that was scheduled (from the most recent policy plan). Stored
    /// so that we can evaluate wake-from-sleep edge cases where timers may have been paused.
    /// Invariant: Mutated only on `stateQueue` inside `reschedule()`.
    private var lastScheduledShutdownDate: Date? = nil

    /// True when a shutdown cycle has completed (final timer fired / performShutdown executed)
    /// but an existing warning alert window from the prior cycle remains visible. While this
    /// flag is set, user interactions with the stale alert should NOT trigger postponement or
    /// mutate the freshly created next-cycle state. Instead we treat any action (postpone / ignore)
    /// as a simple dismissal that enables scheduling for the new cycle. (Immediate shutdown
    /// action is still honored if not a dry-run, though in practice the process will exit.)
    private var cycleCompletedAwaitingAlertDismissal: Bool = false

    /// Create a controller with injected agents; defaults are provided for production runtime.
    /// State is initialized immediately (and persisted unless `--no-persist`). Delegates are then wired.
    init(config: AppConfig,
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
    func start() {
        reschedule()
        logStartup()
    }

    /// Recompute plan & schedule timers (executed on `stateQueue`).
    private func reschedule() {
        stateQueue.async { [self] in
            let now = clock.now()
            guard let plan = policy.plan(for: state, config: config, now: now) else { return }
            // Track the exact shutdown date used for scheduling for subsequent stale-cycle checks.
            lastScheduledShutdownDate = plan.shutdownDate
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
    func warningDue() {
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
                postponeIntervalSeconds: config.effectivePostponeIntervalSeconds
            )
            warningAlertActive = true
            warningPresentedThisCycle = true
            activeAlertCycleOriginalISO = state.originalScheduledShutdownISO
            alertPresenter.present(model: model)
        }
    }

    /// Final shutdown timer fired: initiate shutdown sequence.
    func shutdownDue() {
        performShutdown()
    }

    // MARK: AlertPresenterDelegate
    /// User requested a postpone: validate with policy then mutate state & reschedule.
    func userChosePostpone() {
        stateQueue.async { [self] in
            // If the prior cycle already completed while the alert was visible, ignore the
            // postpone request (treat as dismissal) and schedule the new cycle instead of
            // mutating state or resetting postpone counters.
            if cycleCompletedAwaitingAlertDismissal {
                warningAlertActive = false
                cycleCompletedAwaitingAlertDismissal = false
                activeAlertCycleOriginalISO = nil
                // Allow warnings for the new cycle.
                warningPresentedThisCycle = false
                reschedule()
                return
            }
            // Late postpone guard: if current time is already past (or equal to) the scheduled
            // shutdown time, treat the interaction as a dismissal. This handles races where the
            // final timer hasn't fired yet (e.g., system sleep / wake) but the user attempts to
            // postpone after the deadline. We intentionally do NOT mutate state here.
            if let scheduledDate = StateFactory.parseISO(state.scheduledShutdownISO) {
                if clock.now() >= scheduledDate {
                    log("Ignoring postpone: shutdown time already passed (\(scheduledDate))")
                    warningAlertActive = false
                    activeAlertCycleOriginalISO = nil
                    // Do not clear warningPresentedThisCycle so no new alerts appear for this stale cycle.
                    return
                }
            }
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
    func userChoseShutdownNow() { performShutdown() }
    /// User dismissed/ignored the alert; simply clear the active flag so future warnings can display.
    func userIgnored() {
        stateQueue.async { [self] in
            warningAlertActive = false
            if cycleCompletedAwaitingAlertDismissal {
                // Final timer already advanced the cycle; simply enable scheduling for new cycle.
                cycleCompletedAwaitingAlertDismissal = false
                warningPresentedThisCycle = false
                activeAlertCycleOriginalISO = nil
                reschedule()
                return
            }
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
            // Guard against stale shutdown events caused by the machine sleeping past the
            // originally scheduled day (e.g., lid closed overnight). We only execute a
            // shutdown if (a) we are past the scheduled time AND (b) today is the same
            // calendar day as the scheduled shutdown date. Otherwise we treat it as a
            // stale cycle and roll forward without shutting down.
            if let scheduled = lastScheduledShutdownDate {
                let now = clock.now()
                if now > scheduled {
                    let cal = Calendar.current
                    if !cal.isDate(now, inSameDayAs: scheduled) {
                        log("Skipping stale shutdown: scheduled=\(scheduled) now=\(now) (different day)")
                        warningPresentedThisCycle = false
                        state = StateFactory.newState(now: now, config: config)
                        if !config.options.noPersist { stateStore.save(state) }
                        if !warningAlertActive { reschedule() }
                        return
                    }
                }
            }
            // Reset any active alert state before rolling over.
            // Do NOT clear warningAlertActive here if an alert is being displayed; keep it until
            // user closes it to prevent overlapping alerts across cycle boundary. We still reset
            // the per-cycle flag so that after dismissal a new warning can be shown for the new cycle.
            warningPresentedThisCycle = false
            log("Initiating shutdown dryRun=\(config.options.dryRun)")
            if config.options.dryRun {
                // Dry-run behavior: if running in relative one-off mode (`--in-seconds`), we
                // intentionally DO NOT roll into a new cycle or schedule further timers once
                // the shutdown moment has passed. This matches user expectation of a single
                // demonstration run. For daily mode (no relativeSeconds) we preserve previous
                // behavior of rolling forward to the next day so repeated manual tests are
                // still convenient.
                if config.options.relativeSeconds != nil {
                    log("Dry-run complete (one-off relative). Halting further scheduling.")
                    // Mark that any still-visible alert is now stale; user interaction simply dismisses.
                    if warningAlertActive { cycleCompletedAwaitingAlertDismissal = true }
                    return
                } else {
                    // Daily mode: continue to roll to next day for iterative observation.
                    state = StateFactory.newState(now: clock.now(), config: config)
                    if warningAlertActive { cycleCompletedAwaitingAlertDismissal = true } else { reschedule() }
                    if !config.options.noPersist { stateStore.save(state) }
                    return
                }
            }
            actions.shutdown()
            // Schedule next cycle optimistically
            state = StateFactory.newState(now: clock.now(), config: config)
            if !config.options.noPersist { stateStore.save(state) }
            if warningAlertActive {
                cycleCompletedAwaitingAlertDismissal = true
            } else {
                reschedule()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
    }

#if DEBUG
    /// Test-only helper: asynchronously provide the current in-memory state snapshot.
    func _testCurrentState(completion: @escaping (ShutdownState) -> Void) {
        stateQueue.async { completion(self.state) }
    }
#endif
}
