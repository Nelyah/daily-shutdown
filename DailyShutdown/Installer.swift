import Foundation

/// Handles installation of a user LaunchAgent so DailyShutdown runs at login.
/// Side effects are isolated here.
enum Installer {
    private static var fileManager: FileManager { FileManager.default }

    /// Entry point invoked by `daily-shutdown install`.
    static func run() {
        do {
            let exePath = try currentExecutablePath()
            let appSupportBin = try ensureBinaryInstalled(from: exePath)
            let plistPath = try installLaunchAgent(executable: appSupportBin)
            print("Installed LaunchAgent -> \(plistPath)")
            print("Executable location -> \(appSupportBin)")
            // Attempt to load (or reload) immediately.
            _ = runTask("/bin/launchctl", ["unload", plistPath]) // ignore errors (may not be loaded yet)
            let loadResult = runTask("/bin/launchctl", ["load", "-w", plistPath])
            if loadResult.exitCode == 0 {
                print("LaunchAgent loaded (exit=0)")
            } else {
                print("LaunchAgent load returned exit=\(loadResult.exitCode). You may need to run: launchctl load -w \(plistPath)")
            }
            // Print effective config so user immediately sees active settings.
            let effective = CommandLineConfigParser.parseWithFile()
            print("\n# Current Effective Configuration\n" + CommandLineConfigParser.effectiveConfigTOML(effective))
            print("Install complete. DailyShutdown should now start at login.")
        } catch {
            fputs("Install failed: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Uninstall previously installed LaunchAgent and helper binary.
    static func uninstall() {
        let fm = fileManager
        let identifier = "dev.daily.shutdown"
        let agentsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        let plistURL = agentsDir.appendingPathComponent("\(identifier).plist")
        if fm.fileExists(atPath: plistURL.path) {
            _ = runTask("/bin/launchctl", ["unload", plistURL.path])
            do { try fm.removeItem(at: plistURL); print("Removed LaunchAgent plist -> \(plistURL.path)") } catch { print("Failed to remove plist: \(error)") }
        } else {
            print("LaunchAgent plist not found (nothing to remove)")
        }
        let binDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("DailyShutdown", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let binPath = binDir.appendingPathComponent("DailyShutdown")
        if fm.fileExists(atPath: binPath.path) {
            do { try fm.removeItem(at: binPath); print("Removed installed binary -> \(binPath.path)") } catch { print("Failed to remove binary: \(error)") }
        } else {
            print("Installed binary not found (nothing to remove)")
        }
        print("Uninstall complete.")
    }

    /// Resolve the currently running executable location.
    private static func currentExecutablePath() throws -> String {
        let path = CommandLine.arguments.first ?? ""
        guard !path.isEmpty else { throw InstallError.unableToLocateExecutable }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Copy the running executable into ~/Library/Application Support/DailyShutdown/bin/DailyShutdown
    /// (overwriting any existing copy) to provide a stable path for the LaunchAgent.
    private static func ensureBinaryInstalled(from sourcePath: String) throws -> String {
        let supportDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("DailyShutdown", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let dest = supportDir.appendingPathComponent("DailyShutdown")
        if fileManager.fileExists(atPath: dest.path) {
            _ = try? fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(atPath: sourcePath, toPath: dest.path)
        // Ensure executable permission remains (copy preserves, but be defensive)
        let attrs = try fileManager.attributesOfItem(atPath: dest.path)
        if let perms = attrs[.posixPermissions] as? NSNumber {
            let mode = perms.uint16Value | 0o755
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: dest.path)
        }
        return dest.path
    }

    /// Install (write / overwrite) a LaunchAgent plist referencing the given executable.
    /// The agent runs the binary with no extra flags; user can still configure via TOML file.
    private static func installLaunchAgent(executable: String) throws -> String {
        let agentsDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let identifier = "dev.daily.shutdown"
        let plistURL = agentsDir.appendingPathComponent("\(identifier).plist")
        let programArgs: [String] = [executable]
        let dict: [String: Any] = [
            "Label": identifier,
            "ProgramArguments": programArgs,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plistURL)
        return plistURL.path
    }

    enum InstallError: Error, CustomStringConvertible {
        case unableToLocateExecutable
        var description: String {
            switch self {
            case .unableToLocateExecutable: return "Unable to determine path to running executable"
            }
        }
    }

    // MARK: - Helpers
    private struct TaskResult { let exitCode: Int32 }
    @discardableResult private static func runTask(_ path: String, _ args: [String]) -> TaskResult {
        let proc = Process()
        proc.launchPath = path
        proc.arguments = args
        do { try proc.run(); proc.waitUntilExit() } catch { return TaskResult(exitCode: -1) }
        return TaskResult(exitCode: proc.terminationStatus)
    }
}
