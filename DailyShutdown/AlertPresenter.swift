import AppKit
import Foundation

public protocol AlertPresenterDelegate: AnyObject {
    func userChosePostpone()
    func userChoseShutdownNow()
    func userIgnored()
}

public struct AlertModel {
    public let scheduled: Date
    public let original: Date
    public let postponesUsed: Int
    public let maxPostpones: Int
    public let postponeIntervalMinutes: Int
}

public protocol AlertPresenting: AnyObject {
    var delegate: AlertPresenterDelegate? { get set }
    func present(model: AlertModel)
}

public final class AlertPresenter: AlertPresenting {
    public weak var delegate: AlertPresenterDelegate?
    public init() {}

    public func present(model: AlertModel) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            let df = DateFormatter()
            df.timeStyle = .short
            let timeStr = df.string(from: model.scheduled)
            let originalStr = df.string(from: model.original)
            let remaining = max(0, model.maxPostpones - model.postponesUsed)

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Scheduled System Shutdown"
            alert.informativeText = """
The system is scheduled to shutdown at \(timeStr).
Original plan: \(originalStr).
You may postpone up to \(remaining) more time(s).
"""
            if model.postponesUsed < model.maxPostpones {
                alert.addButton(withTitle: "Postpone \(model.postponeIntervalMinutes) min")
            }
            alert.addButton(withTitle: "Shutdown Now")
            alert.addButton(withTitle: "Ignore")

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
