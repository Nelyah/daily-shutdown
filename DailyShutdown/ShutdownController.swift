import Foundation
import AppKit

/// Orchestrates the full shutdown cycle: loading/creating state, computing policy plans,
/// scheduling timers, presenting alerts, handling user actions, and initiating system shutdown.
/// Thread-safety: state mutations are serialized via `stateQueue`.
public final class ShutdownController: SchedulerDelegate, AlertPresenterDelegate {
    private let config: AppConfig
    private let stateStore: StateStore
    private var state: ShutdownState
    private let clock: Clock
    private let policy: ShutdownPolicyType
    private let scheduler: Scheduler
    private let actions: SystemActions
    private let alertPresenter: AlertPresenting
    private let stateQueue = DispatchQueue(label: "shutdown.controller.state", qos: .userInitiated)

    private let workDir: URL

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
            let df = DateFormatter(); df.timeStyle = .short
            log("Scheduled shutdown at \(df.string(from: date))")
        }
    }

    // MARK: SchedulerDelegate
    /// Warning timer fired: present alert with current model details.
    public func warningDue() {
        stateQueue.async { [self] in
            guard let shutdownDate = StateFactory.parseISO(state.scheduledShutdownISO),
                  let originalDate = StateFactory.parseISO(state.originalScheduledShutdownISO) else { return }
            let model = AlertModel(
                scheduled: shutdownDate,
                original: originalDate,
                postponesUsed: state.postponesUsed,
                maxPostpones: config.effectiveMaxPostpones,
                postponeIntervalMinutes: Int(round(Double(config.effectivePostponeIntervalSeconds)/60.0))
            )
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
            guard policy.canPostpone(state: state, config: config) else { return }
            policy.applyPostpone(state: &state, config: config, now: clock.now())
            if !config.options.noPersist { stateStore.save(state) }
            log("Postponed: new time = \(state.scheduledShutdownISO) uses=\(state.postponesUsed)/\(config.effectiveMaxPostpones)")
            reschedule()
        }
    }

    /// User chose immediate shutdown.
    public func userChoseShutdownNow() { performShutdown() }
    /// User dismissed/ignored the alert; no action needed.
    public func userIgnored() { /* no-op */ }

    /// Perform (or simulate) system shutdown, roll state into next cycle, and schedule again.
    private func performShutdown() {
        stateQueue.async { [self] in
            log("Initiating shutdown dryRun=\(config.options.dryRun)")
            if config.options.dryRun {
                // Roll over to next day for demonstration
                state = StateFactory.newState(now: clock.now(), config: config)
                if !config.options.noPersist { stateStore.save(state) }
                reschedule()
                return
            }
            actions.shutdown()
            // Schedule next cycle optimistically
            state = StateFactory.newState(now: clock.now(), config: config)
            if !config.options.noPersist { stateStore.save(state) }
            reschedule()
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
