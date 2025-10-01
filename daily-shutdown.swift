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
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + date.timeIntervalSinceNow)
        timer.setEventHandler { [weak self] in
            self?.presentWarning()
        }
        warningTimer = timer
        timer.activate()
    }
    
    private func scheduleFinal(at date: Date) {
          // Use a global queue so the timer is not blocked by any modal alert on the main thread.
          let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
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
            // If we are already past the scheduled shutdown time, execute immediately.
            if shutdownDate <= Date() {
                self.performFinalAction(immediate: true)
                return
            }
            
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
        state.postponesUsed += 1
        if var shutdownDate = isoFormatter.date(from: state.scheduledShutdownISO) {
            shutdownDate.addTimeInterval(TimeInterval(effectivePostponeIntervalSeconds))
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
            print("[DRY RUN] Would \(action == .reboot ? "reboot" : "shutdown") now at \(Date())"); fflush(stdout)
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
