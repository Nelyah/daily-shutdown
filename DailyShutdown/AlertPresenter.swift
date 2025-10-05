import AppKit
import Foundation

/// Delegate receiving user decisions from an alert presentation.
public protocol AlertPresenterDelegate: AnyObject {
    func userChosePostpone()
    func userChoseShutdownNow()
    func userIgnored()
}

/// Immutable data passed to the UI describing the current shutdown scenario.
public struct AlertModel {
    public let scheduled: Date
    public let original: Date
    public let postponesUsed: Int
    public let maxPostpones: Int
    /// Raw postpone interval in seconds (from effective configuration at alert time).
    public let postponeIntervalSeconds: Int
    /// Convenience minute rounding for textual display when >= 2 minutes.
    public var postponeIntervalMinutes: Int { Int(round(Double(postponeIntervalSeconds)/60.0)) }
}

/// Interface for presenting a shutdown warning to the user.
public protocol AlertPresenting: AnyObject {
    var delegate: AlertPresenterDelegate? { get set }
    func present(model: AlertModel)
}

public final class AlertPresenter: AlertPresenting {
    public weak var delegate: AlertPresenterDelegate?
    public init() {}

    /// Build the informative text displayed in the alert for a given model.
    /// Extracted to enable deterministic unit tests without invoking AppKit modals.
    /// - Returns: Multi-line string describing the shutdown plan and postpone status.
    static func buildInformativeText(model: AlertModel, dateFormatter: DateFormatter) -> String {
        let timeStr = dateFormatter.string(from: model.scheduled)
        let originalStr = dateFormatter.string(from: model.original)
        let remaining = max(0, model.maxPostpones - model.postponesUsed)
        let postponeLine: String
        if remaining > 0 {
            postponeLine = "You may postpone up to \(remaining) more time(s)."
        } else {
            postponeLine = "No postpones remaining."
        }
        return """
The system is scheduled to shutdown at \(timeStr).
Original plan: \(originalStr).
\(postponeLine)
"""
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
    public func present(model: AlertModel) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            let df = DateFormatter()
            df.timeStyle = .short
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Scheduled System Shutdown"
            alert.informativeText = Self.buildInformativeText(model: model, dateFormatter: df)
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
