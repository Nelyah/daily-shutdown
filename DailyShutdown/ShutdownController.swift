import Foundation
import AppKit

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

    public func start() {
        reschedule()
        logStartup()
    }

    private func reschedule() {
        stateQueue.async { [self] in
            let now = clock.now()
            guard let plan = policy.plan(for: state, config: config, now: now) else { return }
            scheduler.schedule(shutdownDate: plan.shutdownDate, warningDate: plan.warningDate)
        }
    }

    private func logStartup() {
        if let date = StateFactory.parseISO(state.scheduledShutdownISO) {
            let df = DateFormatter(); df.timeStyle = .short
            log("Scheduled shutdown at \(df.string(from: date))")
        }
    }

    // MARK: SchedulerDelegate
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

    public func shutdownDue() {
        performShutdown()
    }

    // MARK: AlertPresenterDelegate
    public func userChosePostpone() {
        stateQueue.async { [self] in
            guard policy.canPostpone(state: state, config: config) else { return }
            policy.applyPostpone(state: &state, config: config, now: clock.now())
            if !config.options.noPersist { stateStore.save(state) }
            log("Postponed: new time = \(state.scheduledShutdownISO) uses=\(state.postponesUsed)/\(config.effectiveMaxPostpones)")
            reschedule()
        }
    }

    public func userChoseShutdownNow() { performShutdown() }
    public func userIgnored() { /* no-op */ }

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
}
