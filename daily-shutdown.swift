import Foundation
import AppKit

// MARK: - Configuration
let dailyShutdownHour = 16
let dailyShutdownMinute = 6
let warningLeadMinutes = 15
let postponeIntervalMinutes = 15
let maxPostpones = 3
let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/DailyShutdown", isDirectory: true)
let stateFile = stateDir.appendingPathComponent("state.json")

// MARK: - Runtime / Testing Overrides

struct RuntimeOptions {
    var relativeSeconds: Int? = nil          // --in-seconds N
    var warnLeadSeconds: Int? = nil          // --warn-seconds S
    var dryRun = false                       // --dry-run (no real shutdown/reboot)
    var noPersist = false                    // --no-persist (do not read/write state file)
    var actionOverride: FinalAction? = nil   // --action shutdown|reboot
    var postponeIntervalMinutesOverride: Int? = nil // --postpone-min M
    var maxPostponesOverride: Int? = nil     // --max-postpones K
}

let opts: RuntimeOptions = {
    var o = RuntimeOptions()
    var it = CommandLine.arguments.makeIterator()
    _ = it.next() // skip executable name
    while let a = it.next() {
        switch a {
        case "--in-seconds":
            if let v = it.next(), let s = Int(v) { o.relativeSeconds = s }
        case "--warn-seconds":
            if let v = it.next(), let s = Int(v) { o.warnLeadSeconds = s }
        case "--dry-run":
            o.dryRun = true
        case "--no-persist":
            o.noPersist = true
        case "--action":
            if let v = it.next(), let act = FinalAction(rawValue: v) { o.actionOverride = act }
        case "--postpone-min":
            if let v = it.next(), let m = Int(v) { o.postponeIntervalMinutesOverride = m }
        case "--max-postpones":
            if let v = it.next(), let m = Int(v) { o.maxPostponesOverride = m }
        default:
            // Unknown flag: ignore (could print help)
            break
        }
    }
    return o
}()

// Effective (possibly overridden) configuration
let effectiveWarningLeadSeconds: TimeInterval = {
    if let s = opts.warnLeadSeconds { return TimeInterval(s) }
    return TimeInterval(warningLeadMinutes * 60)
}()

let effectivePostponeIntervalMinutes = opts.postponeIntervalMinutesOverride ?? postponeIntervalMinutes
let effectiveMaxPostpones = opts.maxPostponesOverride ?? maxPostpones

enum FinalAction: String, Codable {
    case shutdown
    case reboot
}

struct ShutdownState: Codable {
    var date: String              // "YYYY-MM-DD"
    var postponesUsed: Int
    var scheduledShutdownISO: String
    var finalAction: FinalAction
}

final class ShutdownManager {
    private var state: ShutdownState
    private let calendar = Calendar.current
    private var warningTimer: DispatchSourceTimer?
    private var finalTimer: DispatchSourceTimer?
    
    init() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if opts.noPersist {
            self.state = Self.newState(for: Date())
        } else {
            self.state = Self.loadState() ?? Self.newState(for: Date())
        }
        // If a relative test run is requested, always create a fresh relative state
        if opts.relativeSeconds != nil {
            self.state = Self.newState(for: Date())
        }
        if let override = opts.actionOverride {
            self.state.finalAction = override
        }
        normalizeForToday()
        scheduleAll()
    }
    
    // MARK: - State Handling
    private static func newState(for now: Date) -> ShutdownState {
        // If test relative schedule supplied, schedule that many seconds from now
        if let rel = opts.relativeSeconds {
            let shutdownDate = now.addingTimeInterval(TimeInterval(rel))
            let dateStamp = dateFormatter.string(from: now)
            return ShutdownState(
                date: dateStamp,
                postponesUsed: 0,
                scheduledShutdownISO: isoFormatter.string(from: shutdownDate),
                finalAction: .shutdown
            )
        }
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = dailyShutdownHour
        components.minute = dailyShutdownMinute
        components.second = 0
        var shutdownDate = calendar.date(from: components)!
        if shutdownDate <= now {
            // Move to tomorrow
            shutdownDate = calendar.date(byAdding: .day, value: 1, to: shutdownDate)!
        }
        let dateStamp = dateFormatter.string(from: now)
        return ShutdownState(
            date: dateStamp,
            postponesUsed: 0,
            scheduledShutdownISO: isoFormatter.string(from: shutdownDate),
            finalAction: .shutdown
        )
    }
    
    private static func loadState() -> ShutdownState? {
        if opts.noPersist { return nil }
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(ShutdownState.self, from: data)
    }
    
    private func saveState() {
        if opts.noPersist { return }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
    
    private func normalizeForToday() {
        let today = dateFormatter.string(from: Date())
        if state.date != today {
            // Reset for new day
            state = Self.newState(for: Date())
            saveState()
        } else {
            // Ensure scheduled time is still in future; if not, roll to next day
            if let sched = isoFormatter.date(from: state.scheduledShutdownISO), sched <= Date() {
                state = Self.newState(for: Date())
                saveState()
            }
        }
    }
    
    // MARK: - Scheduling
    private func scheduleAll() {
        cancelTimers()
        guard let shutdownDate = isoFormatter.date(from: state.scheduledShutdownISO) else { return }
        scheduleFinal(at: shutdownDate)
        
        if state.postponesUsed < effectiveMaxPostpones {
            let warningDate = shutdownDate.addingTimeInterval(-effectiveWarningLeadSeconds)
            if warningDate > Date() {
                scheduleWarning(at: warningDate)
            } else {
                // If warning time already passed (e.g. app started late), show immediately (once)
                DispatchQueue.main.async { self.presentWarning() }
            }
        }
    }
    
    private func scheduleWarning(at date: Date) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + date.timeIntervalSinceNow)
        timer.setEventHandler { [weak self] in
            self?.presentWarning()
        }
        warningTimer = timer
        timer.activate()
    }
    
    private func scheduleFinal(at date: Date) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + date.timeIntervalSinceNow)
        timer.setEventHandler { [weak self] in
            self?.performFinalAction()
        }
        finalTimer = timer
        timer.activate()
    }
    
    private func cancelTimers() {
        warningTimer?.cancel()
        finalTimer?.cancel()
        warningTimer = nil
        finalTimer = nil
    }
    
    // MARK: - UI & Actions
    private func presentWarning() {
        guard let shutdownDate = isoFormatter.date(from: state.scheduledShutdownISO) else { return }
        DispatchQueue.main.async {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let timeStr = formatter.string(from: shutdownDate)
            let remaining = effectiveMaxPostpones - self.state.postponesUsed
            
            // Ensure app is frontmost and eligible for regular windows each time.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Scheduled System \(self.state.finalAction == .reboot ? "Reboot" : "Shutdown")"
            alert.informativeText = """
The system is scheduled at \(timeStr).
You may postpone up to \(remaining) more time(s).
"""
            if self.state.postponesUsed < effectiveMaxPostpones {
                alert.addButton(withTitle: "Postpone \(effectivePostponeIntervalMinutes) min")
            }
            alert.addButton(withTitle: self.state.finalAction == .reboot ? "Reboot Now" : "Shutdown Now")
            alert.addButton(withTitle: "Ignore")
            
            // Elevate window above normal app windows and show on all Spaces (incl. full screen).
            let w = alert.window
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.isReleasedWhenClosed = false
            w.makeKeyAndOrderFront(nil)
            
            // Request user attention (Dock bounce) for visibility.
            NSApp.requestUserAttention(.criticalRequest)
            
            let response = alert.runModal()
            self.handleWarningResponse(response)
        }
    }
    
    private func handleWarningResponse(_ response: NSApplication.ModalResponse) {
        // Button order depends on which buttons were added:
        // If postpones available:
        //   First: Postpone, Second: Shutdown/Reboot Now, Third: Ignore
        // If no postpones (not shown, but logic ensures we don't call warning when no postpones):
        //   First: Shutdown/Reboot Now, Second: Ignore
        if state.postponesUsed < effectiveMaxPostpones {
            if response == .alertFirstButtonReturn {
                applyPostpone()
                return
            } else if response == .alertSecondButtonReturn {
                performFinalAction(immediate: true)
                return
            } else {
                // Ignore: do nothing
                return
            }
        } else {
            if response == .alertFirstButtonReturn {
                performFinalAction(immediate: true)
            }
        }
    }
    
    private func applyPostpone() {
        state.postponesUsed += 1
        if var shutdownDate = isoFormatter.date(from: state.scheduledShutdownISO) {
            shutdownDate.addTimeInterval(TimeInterval(effectivePostponeIntervalMinutes * 60))
            state.scheduledShutdownISO = isoFormatter.string(from: shutdownDate)
        }
        if state.postponesUsed >= effectiveMaxPostpones {
            state.finalAction = .reboot
            // After final postpone: no further warning, just final timer at updated time
        }
        saveState()
        scheduleAll()
    }
    
    private func performFinalAction(immediate: Bool = false) {
        // Fire actual system command
        let action = state.finalAction
        if opts.dryRun {
            print("[DRY RUN] Would \(action == .reboot ? "reboot" : "shutdown") now at \(Date())")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                exit(0)
            }
            return
        }
        let script: String
        switch action {
        case .shutdown:
            script = #"tell application "System Events" to shut down"#
        case .reboot:
            script = #"tell application "System Events" to restart"#
        }
        
        // Run AppleScript
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
        
        // Exit after short delay to allow LaunchAgent to restart fresh next login
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            exit(0)
        }
    }
}

// MARK: - Formatters
private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

// MARK: - Main
let app = NSApplication.shared
if opts.relativeSeconds != nil || opts.dryRun {
    app.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
}
let manager = ShutdownManager()
RunLoop.main.run()
