import Foundation

/// Handles installation of a user LaunchAgent so DailyShutdown runs at login.
/// Side effects are isolated here.
// Captured launchctl commands in test mode (when DAILY_SHUTDOWN_INSTALL_TEST_MODE=1)
var installerCapturedCommands: [String] = []

enum Installer {
    // MARK: Constants & Environment
    private enum C {
        static let label = "dev.daily.shutdown"
        static let binaryName = "DailyShutdown"
    }
    private static var fileManager: FileManager { FileManager.default }
    private static var env: [String:String] { ProcessInfo.processInfo.environment }

    // Encapsulates all filesystem locations used for install/uninstall derived from a (possibly overridden) home directory.
    private struct InstallPaths {
        let home: URL
        var agentsDir: URL { home.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }
        var appSupportDir: URL { home.appendingPathComponent("Library/Application Support/DailyShutdown", isDirectory: true) }
        var binDir: URL { appSupportDir.appendingPathComponent("bin", isDirectory: true) }
        var binary: URL { binDir.appendingPathComponent(C.binaryName) }
        var plist: URL { agentsDir.appendingPathComponent("\(C.label).plist") }
    }

    /// Resolve the effective home directory (test override supported via DAILY_SHUTDOWN_HOME_OVERRIDE).
    private static func resolvedHomeDirectory() -> URL {
        if let override = env["DAILY_SHUTDOWN_HOME_OVERRIDE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    private static func makePaths() -> InstallPaths { InstallPaths(home: resolvedHomeDirectory()) }

    /// Entry point invoked by `daily-shutdown install`.
    static func run() {
        do {
            let paths = makePaths()
            let sourceBinary = try resolveCurrentExecutable()
            try stageBinary(source: sourceBinary, to: paths.binary)
            try writeLaunchAgentPlist(paths: paths)
            print("Installed LaunchAgent -> \(paths.plist.path)")
            print("Executable location -> \(paths.binary.path)")
            // Modern launchd workflow: bootout (ignore errors) then bootstrap.
            let uid = getuid()
            let domain = "gui/\(uid)"
            // bootout expects domain/label path
            _ = runTask("/bin/launchctl", ["bootout", "\(domain)/\(C.label)"]) // ignore failures if not loaded
            let bootstrapResult = runTask("/bin/launchctl", ["bootstrap", domain, paths.plist.path])
            if bootstrapResult.exitCode == 0 {
                print("LaunchAgent bootstrapped into domain \(domain) (exit=0)")
            } else {
                print("LaunchAgent bootstrap returned exit=\(bootstrapResult.exitCode). Try manually: launchctl bootout \(domain)/\(C.label); launchctl bootstrap \(domain) \(paths.plist.path)")
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
        let paths = makePaths()
        let fm = fileManager
        if fm.fileExists(atPath: paths.plist.path) {
            let uid = getuid(); let domain = "gui/\(uid)"
            _ = runTask("/bin/launchctl", ["bootout", "\(domain)/\(C.label)"]) // ignore errors
            do { try fm.removeItem(at: paths.plist); print("Removed LaunchAgent plist -> \(paths.plist.path)") } catch { print("Failed to remove plist: \(error)") }
        } else {
            print("LaunchAgent plist not found (nothing to remove)")
        }
        if fm.fileExists(atPath: paths.binary.path) {
            do { try fm.removeItem(at: paths.binary); print("Removed installed binary -> \(paths.binary.path)") } catch { print("Failed to remove binary: \(error)") }
        } else {
            print("Installed binary not found (nothing to remove)")
        }
        print("Uninstall complete.")
    }

    /// Determine the path of the currently running executable (or overridden path in tests).
    private static func resolveCurrentExecutable() throws -> String {
        if let override = env["DAILY_SHUTDOWN_EXECUTABLE_OVERRIDE"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL.path
        }
        let path = CommandLine.arguments.first ?? ""
        guard !path.isEmpty else { throw InstallError.unableToLocateExecutable }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Copy the running executable to the managed binary path (overwriting existing copy).
    private static func stageBinary(source: String, to destinationPath: URL) throws {
        try fileManager.createDirectory(at: destinationPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationPath.path) { _ = try? fileManager.removeItem(at: destinationPath) }
        try fileManager.copyItem(atPath: source, toPath: destinationPath.path)
        // Reassert executable permissions (defensive).
        let attrs = try fileManager.attributesOfItem(atPath: destinationPath.path)
        if let perms = attrs[.posixPermissions] as? NSNumber {
            let mode = perms.uint16Value | 0o755
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: destinationPath.path)
        }
    }

    /// Write (overwrite) the LaunchAgent property list pointing at the staged binary.
    private static func writeLaunchAgentPlist(paths: InstallPaths) throws {
        try fileManager.createDirectory(at: paths.agentsDir, withIntermediateDirectories: true)
        let dict: [String: Any] = [
            "Label": C.label,
            "ProgramArguments": [paths.binary.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: paths.plist)
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
