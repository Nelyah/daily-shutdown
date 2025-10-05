import Foundation

/// Handles installation of a user LaunchAgent so DailyShutdown runs at login.
/// Side effects are isolated here.
// Captured launchctl commands in test mode (when DAILY_SHUTDOWN_INSTALL_TEST_MODE=1)
var installerCapturedCommands: [String] = []

enum Installer {
    private static var fileManager: FileManager { FileManager.default }
    private static var env: [String:String] { ProcessInfo.processInfo.environment }

    /// Resolve the effective home directory (test override supported via DAILY_SHUTDOWN_HOME_OVERRIDE).
    private static func homeDir() -> URL {
        if let override = env["DAILY_SHUTDOWN_HOME_OVERRIDE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    /// Entry point invoked by `daily-shutdown install`.
    static func run() {
        do {
            let exePath = try currentExecutablePath()
            let appSupportBin = try ensureBinaryInstalled(from: exePath)
            let plistPath = try installLaunchAgent(executable: appSupportBin)
            print("Installed LaunchAgent -> \(plistPath)")
            print("Executable location -> \(appSupportBin)")
            // Modern launchd workflow: bootout (ignore errors) then bootstrap.
            let uid = getuid()
            let domain = "gui/\(uid)"
            let label = "dev.daily.shutdown"
            // bootout expects domain/label path
            _ = runTask("/bin/launchctl", ["bootout", "\(domain)/\(label)"]) // ignore failures if not loaded
            let bootstrapResult = runTask("/bin/launchctl", ["bootstrap", domain, plistPath])
            if bootstrapResult.exitCode == 0 {
                print("LaunchAgent bootstrapped into domain \(domain) (exit=0)")
            } else {
                print("LaunchAgent bootstrap returned exit=\(bootstrapResult.exitCode). Try manually: launchctl bootout \(domain)/\(label); launchctl bootstrap \(domain) \(plistPath)")
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
        let agentsDir = homeDir()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        let plistURL = agentsDir.appendingPathComponent("\(identifier).plist")
        if fm.fileExists(atPath: plistURL.path) {
            let uid = getuid()
            let domain = "gui/\(uid)"
            _ = runTask("/bin/launchctl", ["bootout", "\(domain)/\(identifier)"]) // ignore failure
            do { try fm.removeItem(at: plistURL); print("Removed LaunchAgent plist -> \(plistURL.path)") } catch { print("Failed to remove plist: \(error)") }
        } else {
            print("LaunchAgent plist not found (nothing to remove)")
        }
        let binDir = homeDir()
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
        if let override = env["DAILY_SHUTDOWN_EXECUTABLE_OVERRIDE"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL.path
        }
        let path = CommandLine.arguments.first ?? ""
        guard !path.isEmpty else { throw InstallError.unableToLocateExecutable }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Copy the running executable into ~/Library/Application Support/DailyShutdown/bin/DailyShutdown
    /// (overwriting any existing copy) to provide a stable path for the LaunchAgent.
    private static func ensureBinaryInstalled(from sourcePath: String) throws -> String {
        let supportDir = homeDir()
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
        let agentsDir = homeDir()
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
        let testMode = env["DAILY_SHUTDOWN_INSTALL_TEST_MODE"] == "1"
        if testMode {
            installerCapturedCommands.append(([path] + args).joined(separator: " "))
            // Simulate success for bootstrap; neutral for bootout
            let isBootstrap = args.first == "bootstrap"
            return TaskResult(exitCode: isBootstrap ? 0 : 0)
        }
        let proc = Process()
        proc.launchPath = path
        proc.arguments = args
        do { try proc.run(); proc.waitUntilExit() } catch { return TaskResult(exitCode: -1) }
        return TaskResult(exitCode: proc.terminationStatus)
    }
}
