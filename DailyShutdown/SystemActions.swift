import Foundation

public protocol SystemActions {
    func shutdown()
}

public final class AppleScriptSystemActions: SystemActions {
    public init() {}
    public func shutdown() {
        let script = "tell application \"System Events\" to shut down"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        do { try task.run(); log("Launched shutdown AppleScript pid=\(task.processIdentifier)") } catch {
            log("Failed to launch shutdown AppleScript: \(error)")
        }
    }
}
