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
        self.state = Self.loadState() ?? Self.newState(for: Date())
        normalizeForToday()
        scheduleAll()
    }
    
    // MARK: - State Handling
    private static func newState(for now: Date) -> ShutdownState {
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
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(ShutdownState.self, from: data)
    }
    
    private func saveState() {
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
        
        if state.postponesUsed < maxPostpones {
            let warningDate = shutdownDate.addingTimeInterval(TimeInterval(-warningLeadMinutes * 60))
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
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let timeStr = formatter.string(from: shutdownDate)
        let remaining = maxPostpones - state.postponesUsed
        let alert = NSAlert()
        alert.messageText = "Scheduled System \(state.finalAction == .reboot ? "Reboot" : "Shutdown")"
        alert.informativeText = """
The system is scheduled at \(timeStr).
You may postpone up to \(remaining) more time(s).
"""
        if state.postponesUsed < maxPostpones {
            alert.addButton(withTitle: "Postpone \(postponeIntervalMinutes) min")
        }
        alert.addButton(withTitle: state.finalAction == .reboot ? "Reboot Now" : "Shutdown Now")
        alert.addButton(withTitle: "Ignore")
        
        let response = alert.runModal()
        handleWarningResponse(response)
    }
    
    private func handleWarningResponse(_ response: NSApplication.ModalResponse) {
        // Button order depends on which buttons were added:
        // If postpones available:
        //   First: Postpone, Second: Shutdown/Reboot Now, Third: Ignore
        // If no postpones (not shown, but logic ensures we don't call warning when no postpones):
        //   First: Shutdown/Reboot Now, Second: Ignore
        if state.postponesUsed < maxPostpones {
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
            shutdownDate.addTimeInterval(TimeInterval(postponeIntervalMinutes * 60))
            state.scheduledShutdownISO = isoFormatter.string(from: shutdownDate)
        }
        if state.postponesUsed >= maxPostpones {
            state.finalAction = .reboot
            // After 3rd postpone: no further warning, just final timer at updated time
        }
        saveState()
        scheduleAll()
    }
    
    private func performFinalAction(immediate: Bool = false) {
        // Fire actual system command
        let action = state.finalAction
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
let manager = ShutdownManager()
RunLoop.main.run()
