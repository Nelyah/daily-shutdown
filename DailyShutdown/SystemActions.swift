import Foundation

/// Abstraction for performing system-level side effects (shutdown, etc.).
public protocol SystemActions {
    func shutdown()
}

public final class AppleScriptSystemActions: SystemActions {
    public init() {}
    /// Attempt to trigger a macOS shutdown via AppleScript (`osascript`).
    /// Logs success/failure; no guarantee the OS honors the request immediately.
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
