import Foundation
import AppKit
import Darwin

// Revert to classic stdout/stderr logging with immediate flush.
setbuf(stdout, nil)
setbuf(stderr, nil)

// MARK: - Configuration
let dailyShutdownHour = 18
let dailyShutdownMinute = 0
let warningLeadMinutes = 15
let postponeIntervalMinutes = 15
let maxPostpones = 3
let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/DailyShutdown", isDirectory: true)
let stateFile = stateDir.appendingPathComponent("state.json")
let resumePrefsFile = stateDir.appendingPathComponent("resume-prefs.json")

// MARK: - Runtime / Testing Overrides

struct RuntimeOptions {
    var relativeSeconds: Int? = nil          // --in-seconds N
    var warnLeadSeconds: Int? = nil          // --warn-seconds S
    var dryRun = false                       // --dry-run (no real shutdown/reboot)
    var noPersist = false                    // --no-persist (do not read/write state file)
    var actionOverride: FinalAction? = nil   // --action shutdown|reboot
    var postponeIntervalSecondsOverride: Int? = nil // --postpone-min S (value now interpreted as seconds)
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
        case "--postpone-sec":
            if let v = it.next(), let m = Int(v) { o.postponeIntervalSecondsOverride = m }
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

// CLI override (--postpone-min) now supplies seconds directly. If not provided, use default minutes * 60.
let effectivePostponeIntervalSeconds: Int = {
    if let v = opts.postponeIntervalSecondsOverride { return v } // already seconds
    return postponeIntervalMinutes * 60
}()
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
    // Preserve the originally scheduled shutdown time (before any postpones).
    // Optional for backward compatibility with older state files.
    var originalScheduledShutdownISO: String?
}

final class ShutdownManager {
    private var state: ShutdownState
    private let calendar = Calendar.current
    private var warningTimer: DispatchSourceTimer?
    // finalTimer runs on a background queue so it can fire even while a modal alert is presented.
    private var finalTimer: DispatchSourceTimer?
    private var activeWarningAlert: NSAlert?
    private var autoShutdownTimer: DispatchSourceTimer?
    private var keepFrontTimer: DispatchSourceTimer?
    
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
        // Backward compatibility: if original not stored, set it now.
        if self.state.originalScheduledShutdownISO == nil {
            self.state.originalScheduledShutdownISO = self.state.scheduledShutdownISO
            saveState()
        }
        // Restore original resume preferences if we suppressed them during last forced shutdown.
        restoreResumePrefsIfNeeded()
        normalizeForToday()
        scheduleAll()
        // Log the scheduled shutdown time at startup (even without CLI arguments).
        logScheduledStartup()
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
                finalAction: .shutdown,
                originalScheduledShutdownISO: isoFormatter.string(from: shutdownDate)
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
            finalAction: .shutdown,
            originalScheduledShutdownISO: isoFormatter.string(from: shutdownDate)
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
    
    // MARK: - Resume Preference Handling
    private struct ResumePrefs: Codable {
        var launchRelaunchApps: Bool?
        var talLogoutSavesState: Bool?
    }
    
    private func readLoginwindowBool(_ key: String) -> Bool? {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", "com.apple.loginwindow", key]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return nil }
        switch raw {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }
    
    private func writeLoginwindowBool(_ key: String, value: Bool) {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["write", "com.apple.loginwindow", key, "-bool", value ? "true" : "false"]
        try? task.run()
        task.waitUntilExit()
    }
    
    private func restoreResumePrefsIfNeeded() {
        guard let data = try? Data(contentsOf: resumePrefsFile),
              let prefs = try? JSONDecoder().decode(ResumePrefs.self, from: data) else { return }
        if let v = prefs.launchRelaunchApps { writeLoginwindowBool("LoginwindowLaunchesRelaunchApps", value: v) }
        if let v = prefs.talLogoutSavesState { writeLoginwindowBool("TALLogoutSavesState", value: v) }
        try? FileManager.default.removeItem(at: resumePrefsFile)
    }
    
    private func suppressNextLoginResume() {
        if FileManager.default.fileExists(atPath: resumePrefsFile.path) == false {
            let orig = ResumePrefs(
                launchRelaunchApps: readLoginwindowBool("LoginwindowLaunchesRelaunchApps"),
                talLogoutSavesState: readLoginwindowBool("TALLogoutSavesState")
            )
            if let encoded = try? JSONEncoder().encode(orig) {
                try? encoded.write(to: resumePrefsFile, options: .atomic)
            }
        }
        writeLoginwindowBool("LoginwindowLaunchesRelaunchApps", value: false)
        writeLoginwindowBool("TALLogoutSavesState", value: false)
    }
    
    private func normalizeForToday() {
        // Always create a brand-new shutdown state on each program start,
        // ignoring any previously persisted schedule or postpones.
        let now = Date()
        let oldISO = state.scheduledShutdownISO
        state = Self.newState(for: now)
        saveState()
        print("normalizeForToday(): oldScheduled=\(oldISO) newScheduled=\(state.scheduledShutdownISO) postponesUsedReset=0 action=\(state.finalAction)"); fflush(stdout)
    }
    
    // MARK: - Scheduling
    private func scheduleAll() {
        cancelTimers()
        guard let shutdownDate = isoFormatter.date(from: state.scheduledShutdownISO) else {
            print("scheduleAll(): could not parse scheduledShutdownISO=\(state.scheduledShutdownISO)"); fflush(stdout)
            return
        }
        print("scheduleAll(): scheduling finalAction=\(state.finalAction) at \(shutdownDate) (postponesUsed=\(state.postponesUsed)/\(effectiveMaxPostpones))"); fflush(stdout)
        scheduleFinal(at: shutdownDate)
        
        if state.postponesUsed < effectiveMaxPostpones {
            let warningDate = shutdownDate.addingTimeInterval(-effectiveWarningLeadSeconds)
            if warningDate > Date() {
                print("scheduleAll(): scheduling warning at \(warningDate) (lead=\(Int(effectiveWarningLeadSeconds))s)"); fflush(stdout)
                scheduleWarning(at: warningDate)
            } else {
                print("scheduleAll(): warning time already passed, presenting warning immediately"); fflush(stdout)
                // If warning time already passed (e.g. app started late), show immediately (once)
                DispatchQueue.main.async { self.presentWarning() }
            }
        } else {
            print("scheduleAll(): no warning scheduled (max postpones reached)"); fflush(stdout)
        }
    }
    
    private func logScheduledStartup() {
        guard let shutdownDate = isoFormatter.date(from: state.scheduledShutdownISO) else { return }
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        let currentStr = df.string(from: shutdownDate)
        if let origISO = state.originalScheduledShutdownISO,
           let origDate = isoFormatter.date(from: origISO),
           abs(origDate.timeIntervalSince(shutdownDate)) > 1 {
            let origStr = df.string(from: origDate)
            print("Scheduled shutdown at \(currentStr) (original \(origStr))"); fflush(stdout)
        } else {
            print("Scheduled shutdown at \(currentStr)"); fflush(stdout)
        }
    }
    
    private func scheduleWarning(at date: Date) {
        let interval = date.timeIntervalSinceNow
        print("scheduleWarning(): will fire in \(String(format: "%.2f", interval))s at \(date)"); fflush(stdout)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            print("scheduleWarning(): firing warning timer at \(Date())"); fflush(stdout)
            self?.presentWarning()
        }
        warningTimer = timer
        timer.activate()
    }
    
    private func scheduleFinal(at date: Date) {
          // Use a global queue so the timer is not blocked by any modal alert on the main thread.
          let interval = date.timeIntervalSinceNow
          print("scheduleFinal(): will fire in \(String(format: "%.2f", interval))s at \(date) action=\(state.finalAction)"); fflush(stdout)
          let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
          timer.schedule(deadline: .now() + interval)
          timer.setEventHandler { [weak self] in
              print("scheduleFinal(): firing final timer at \(Date())"); fflush(stdout)
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
            print("Presenting warning alert (postponesUsed=\(self.state.postponesUsed), remaining=\(effectiveMaxPostpones - self.state.postponesUsed))"); fflush(stdout)
            // If we are already past the scheduled shutdown time, execute immediately.
            if shutdownDate <= Date() {
                self.performFinalAction(immediate: true)
                return
            }
            
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let timeStr = formatter.string(from: shutdownDate)
            let remaining = effectiveMaxPostpones - self.state.postponesUsed
            
            // Ensure app can present alert without showing Dock icon.
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Scheduled System \(self.state.finalAction == .reboot ? "Reboot" : "Shutdown")"
            // Compute original planned shutdown time if available & different.
            let originalPlannedStr: String? = {
                if let origISO = self.state.originalScheduledShutdownISO,
                   let origDate = isoFormatter.date(from: origISO) {
                    if abs(origDate.timeIntervalSince(shutdownDate)) > 1 { // different
                        let df = DateFormatter()
                        df.timeStyle = .short
                        return df.string(from: origDate)
                    }
                }
                return nil
            }()
            if let orig = originalPlannedStr {
                print("Original planned shutdown at \(orig); current scheduled at \(timeStr)"); fflush(stdout)
            } else {
                print("Scheduled shutdown at \(timeStr)"); fflush(stdout)
            }
            alert.informativeText = """
The system is scheduled to shutdown at \(timeStr).
\(originalPlannedStr != nil ? "Originally planned at \(originalPlannedStr!)." : "")
You may postpone up to \(remaining) more time(s).
"""
            if self.state.postponesUsed < effectiveMaxPostpones {
                  let postponeMinutesDisplay = Int(round(Double(effectivePostponeIntervalSeconds) / 60.0))
                  alert.addButton(withTitle: "Postpone \(postponeMinutesDisplay) min")
            }
            alert.addButton(withTitle: self.state.finalAction == .reboot ? "Reboot Now" : "Shutdown Now")
            alert.addButton(withTitle: "Ignore")

            // Style the destructive (immediate shutdown/reboot) button in red for emphasis.
            // NSAlert buttons array is in the order added (appears right-to-left visually).
            // When postpone is available: [Postpone, Shutdown/Reboot Now, Ignore]
            // When postpone not available (rare here): [Shutdown/Reboot Now, Ignore]
            let buttons = alert.buttons
            let destructiveButton: NSButton? = {
                if self.state.postponesUsed < effectiveMaxPostpones {
                    return buttons.count > 1 ? buttons[1] : nil
                } else {
                    return buttons.first
                }
            }()
            if let destructiveButton {
                if #available(macOS 13.0, *) {
                    destructiveButton.hasDestructiveAction = true
                }
                if #available(macOS 11.0, *) {
                    destructiveButton.contentTintColor = .systemRed
                } else {
                    // Fallback: manually color the title for older systems.
                    destructiveButton.attributedTitle = NSAttributedString(
                        string: destructiveButton.title,
                        attributes: [.foregroundColor: NSColor.red]
                    )
                }
            }

            // Darker background styling for the entire alert window content for stronger focus.
            if let contentView = alert.window.contentView {
                contentView.wantsLayer = true
                // Create a darker red by blending with black, then apply semi-opaque alpha.
                let NSColorBlack = NSColor.black
                contentView.layer?.backgroundColor = NSColorBlack.withAlphaComponent(0.8).cgColor
                contentView.layer?.cornerRadius = 14
                contentView.layer?.masksToBounds = true

                // Make all text labels white for contrast.
                func applyWhiteText(in view: NSView) {
                    for sub in view.subviews {
                        if let tf = sub as? NSTextField {
                            tf.textColor = .white
                            tf.backgroundColor = .clear
                            tf.drawsBackground = false
                        }
                        applyWhiteText(in: sub)
                    }
                }
                applyWhiteText(in: contentView)
            }
            
            // Elevate window above normal app windows and show on all Spaces (incl. full screen).
            let w = alert.window
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false
            w.hidesOnDeactivate = false
            w.center()
            w.makeKeyAndOrderFront(nil)

            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak w] _ in
                guard let w = w else { return }
                w.level = .screenSaver
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }

            self.keepFrontTimer?.cancel()
            let frontTimer = DispatchSource.makeTimerSource(queue: .main)
            frontTimer.schedule(deadline: .now() + 0.5, repeating: 1.0)
            frontTimer.setEventHandler { [weak w] in
                guard let w = w else { return }
                if !w.isKeyWindow {
                    w.level = .screenSaver
                    w.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            self.keepFrontTimer = frontTimer
            frontTimer.activate()
            
            // Request user attention (Dock bounce) for visibility.
            NSApp.requestUserAttention(.criticalRequest)
            
            // Set up auto-shutdown in case user does not interact before scheduled time.
            let remainingInterval = shutdownDate.timeIntervalSinceNow
            if remainingInterval <= 0 {
                // Safety double-check.
                self.performFinalAction(immediate: true)
                return
            }
            self.activeWarningAlert = alert
              // Background queue so it can still trigger during modal session.
              let auto = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            auto.schedule(deadline: .now() + remainingInterval)
            auto.setEventHandler { [weak self] in
                guard let self else { return }
                if self.activeWarningAlert != nil {
                    // User has not interacted; proceed with final action.
                    self.activeWarningAlert = nil
                    self.autoShutdownTimer?.cancel()
                    self.autoShutdownTimer = nil
                    self.performFinalAction(immediate: true)
                }
            }
            self.autoShutdownTimer?.cancel()
            self.autoShutdownTimer = auto
            auto.activate()
            
            let response = alert.runModal()
            // User interacted; cancel pending auto action.
            self.autoShutdownTimer?.cancel()
            self.autoShutdownTimer = nil
            self.activeWarningAlert = nil
            self.keepFrontTimer?.cancel()
            self.keepFrontTimer = nil
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
        let beforeISO = state.scheduledShutdownISO
        state.postponesUsed += 1
        if var shutdownDate = isoFormatter.date(from: state.scheduledShutdownISO) {
            shutdownDate.addTimeInterval(TimeInterval(effectivePostponeIntervalSeconds))
            state.scheduledShutdownISO = isoFormatter.string(from: shutdownDate)
        }
        let changedAction: Bool
        if state.postponesUsed >= effectiveMaxPostpones {
            let previousAction = state.finalAction
            state.finalAction = .reboot
            changedAction = previousAction != state.finalAction
            // After final postpone: no further warning, just final timer at updated time
        } else {
            changedAction = false
        }
        saveState()
        print("applyPostpone(): postponesUsed=\(state.postponesUsed)/\(effectiveMaxPostpones) old=\(beforeISO) new=\(state.scheduledShutdownISO) interval+=\(effectivePostponeIntervalSeconds)s action=\(state.finalAction)\(changedAction ? " (action changed)" : "")"); fflush(stdout)
        scheduleAll()
    }
    
    private func performFinalAction(immediate: Bool = false) {
        // Fire actual system command
        let action = state.finalAction
        print("performFinalAction(): initiating action=\(action) immediate=\(immediate) dryRun=\(opts.dryRun) at \(Date())"); fflush(stdout)
        if opts.dryRun {
            print("[DRY RUN] Would \(action == .reboot ? "reboot" : "shutdown") now at \(Date())"); fflush(stdout)
            // Immediately compute next day's schedule so repeated dry-runs demonstrate rollover behavior.
            normalizeForToday()
            scheduleAll()
            return
        }
        let script: String
        switch action {
        case .shutdown:
            script = #"tell application "System Events" to shut down"#
        case .reboot:
            script = #"tell application "System Events" to restart"#
        }
        
        // Suppress automatic app/window resume for next login while preserving app-specific session data.
        suppressNextLoginResume()
        
        // Run AppleScript
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        do {
            try task.run()
            print("performFinalAction(): launched osascript pid=\(task.processIdentifier)"); fflush(stdout)
        } catch {
            print("performFinalAction(): failed to launch osascript error=\(error)"); fflush(stdout)
        }
        
        // Proactively schedule the next daily shutdown in case the system does NOT actually
        // go down (e.g. user cancels system dialog, lacks privileges, or AppleScript fails).
        normalizeForToday()
        scheduleAll()
        
        // Exit after short delay to allow LaunchAgent to restart fresh next login
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("performFinalAction(): exiting process after grace delay"); fflush(stdout)
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
// Hide Dock icon by using accessory activation policy always.
app.setActivationPolicy(.accessory)
if opts.relativeSeconds != nil || opts.dryRun {
    // Still bring alert windows forward in test/dry-run modes.
    NSApp.activate(ignoringOtherApps: true)
}
let manager = ShutdownManager()
RunLoop.main.run()
