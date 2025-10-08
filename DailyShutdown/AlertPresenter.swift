import AppKit
import Foundation

/// Delegate receiving user decisions from an alert presentation.
protocol AlertPresenterDelegate: AnyObject {
    func userChosePostpone()
    func userChoseShutdownNow()
    func userIgnored()
}

// (moved relativeTime helper inside AlertPresenter for proper scoping)

/// Immutable data passed to the UI describing the current shutdown scenario.
struct AlertModel {
    let scheduled: Date
    let original: Date
    let postponesUsed: Int
    let maxPostpones: Int
    /// Raw postpone interval in seconds (from effective configuration at alert time).
    let postponeIntervalSeconds: Int
    /// Convenience minute rounding for textual display when >= 2 minutes.
    var postponeIntervalMinutes: Int { Int(round(Double(postponeIntervalSeconds)/60.0)) }
}

/// Interface for presenting a shutdown warning to the user.
protocol AlertPresenting: AnyObject {
    /// Delegate for user decisions sourced from presented UI.
    var delegate: AlertPresenterDelegate? { get set }
    /// Present the alert for a given model. Implementations must marshal to main thread if needed.
    func present(model: AlertModel)
}

/// Concrete AppKit alert presenter providing a concise multi-line summary and action guidance.
final class AlertPresenter: AlertPresenting {
    weak var delegate: AlertPresenterDelegate?
    init() {}

    /// Produce a compact human readable relative time description (approximate) used in the alert.
    /// Examples: "45s", "3m", "1h 12m". Values clamp at zero for past dates.
    private static func relativeTime(until date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, date.timeIntervalSince(now)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        if remMinutes == 0 { return "\(hours)h" }
        return "\(hours)h \(remMinutes)m"
    }

    /// Build the informative text displayed in the alert for a given model.
    /// Extracted to enable deterministic unit tests without invoking AppKit modals.
    /// - Returns: Multi-line string describing the shutdown plan and postpone status.
    static func buildInformativeText(model: AlertModel, dateFormatter: DateFormatter, now: Date = Date()) -> String {
        // 'now' parameter enables deterministic unit tests of the dynamic countdown string.
        let timeStr = dateFormatter.string(from: model.scheduled)
        let remainingRelative = Self.relativeTime(until: model.scheduled, now: now)
        var lines: [String] = []
        lines.append("Scheduled: \(timeStr) (in \(remainingRelative))")
        if model.original != model.scheduled { // suppress duplicate original line when unchanged
            let originalStr = dateFormatter.string(from: model.original)
            lines.append("Original:  \(originalStr)")
        }
        let remainingPostpones = max(0, model.maxPostpones - model.postponesUsed)
        if remainingPostpones > 0 {
            let noun = remainingPostpones == 1 ? "postpone" : "postpones"
            lines.append("\(remainingPostpones) \(noun) remaining")
        } else {
            lines.append("No postpones remaining")
        }
        return lines.joined(separator: "\n")
    }

    /// Compute the postpone button title given the interval.
    /// - If interval < 120s show seconds (e.g., "Postpone 90 sec").
    /// - Otherwise show rounded minutes (e.g., "Postpone 5 min").
    static func postponeButtonTitle(seconds: Int) -> String {
        if seconds < 120 { return "Postpone \(seconds) sec" }
        let mins = Int(round(Double(seconds)/60.0))
        return "Postpone \(mins) min"
    }

    /// Present a blocking (modal) critical alert on the main thread, mapping button presses
    /// back to delegate callbacks. Buttons differ depending on remaining postpones.
    func present(model: AlertModel) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            let df = DateFormatter()
            df.timeStyle = .short
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Scheduled System Shutdown"
            alert.informativeText = Self.buildInformativeText(model: model, dateFormatter: df)
            // --- Dynamic countdown update -------------------------------------------------------
            // We want the (in Xs) portion to decrement live. Changing alert.informativeText after the
            // alert view hierarchy is created does not update the label automatically, so we find the
            // underlying NSTextField once and mutate it every second while the modal run loop spins.
            // NOTE: NSAlert.runModal() installs its own run loop mode; we therefore add our timer to
            // both .common and the legacy modal panel mode name so it continues firing.
            func locateInformativeTextField(in view: NSView) -> NSTextField? {
                for sub in view.subviews {
                    if let tf = sub as? NSTextField, tf.stringValue.contains("Scheduled:") { return tf }
                    if let found = locateInformativeTextField(in: sub) { return found }
                }
                return nil
            }
            var informativeField: NSTextField?
            var updateTimer: Timer? = nil
            let makeTimer = {
                Timer(timeInterval: 1.0, repeats: true) { _ in
                    guard let contentView = alert.window.contentView else { return }
                    if informativeField == nil { informativeField = locateInformativeTextField(in: contentView) }
                    guard let field = informativeField else { return }
                    field.stringValue = Self.buildInformativeText(model: model, dateFormatter: df)
                    field.displayIfNeeded()
                    if model.scheduled.timeIntervalSinceNow <= 0 { updateTimer?.invalidate(); updateTimer = nil }
                }
            }
            updateTimer = makeTimer()
            if let t = updateTimer {
                RunLoop.main.add(t, forMode: .common)
                RunLoop.main.add(t, forMode: RunLoop.Mode(rawValue: "NSModalPanelRunLoopMode"))
            }
            // ------------------------------------------------------------------------------------
            if model.postponesUsed < model.maxPostpones {
                alert.addButton(withTitle: Self.postponeButtonTitle(seconds: model.postponeIntervalSeconds))
                // Capture shutdown button to mark as destructive.
                let shutdownButton = alert.addButton(withTitle: "Shutdown Now")
                if #available(macOS 11.0, *) { shutdownButton.hasDestructiveAction = true }
                alert.addButton(withTitle: "Ignore")
            } else {
                // No postpone available; first button is shutdown (destructive).
                let shutdownButton = alert.addButton(withTitle: "Shutdown Now")
                if #available(macOS 11.0, *) { shutdownButton.hasDestructiveAction = true }
                alert.addButton(withTitle: "Ignore")
            }

            let response = alert.runModal()
            // Stop further UI updates now that the user has responded.
            updateTimer?.invalidate(); updateTimer = nil
            if model.postponesUsed < model.maxPostpones {
                if response == .alertFirstButtonReturn { self.delegate?.userChosePostpone(); return }
                if response == .alertSecondButtonReturn { self.delegate?.userChoseShutdownNow(); return }
                self.delegate?.userIgnored(); return
            } else {
                if response == .alertFirstButtonReturn { self.delegate?.userChoseShutdownNow(); return }
                self.delegate?.userIgnored(); return
            }
        }
    }
}
