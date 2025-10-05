import XCTest
@testable import DailyShutdown

final class InstallerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        installerCapturedCommands.removeAll()
    }

    override func tearDown() {
        unsetenv("DAILY_SHUTDOWN_HOME_OVERRIDE")
        unsetenv("DAILY_SHUTDOWN_EXECUTABLE_OVERRIDE")
        unsetenv("DAILY_SHUTDOWN_INSTALL_TEST_MODE")
        super.tearDown()
    }

    func testInstallCreatesPlistAndBinaryAndBootstraps() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Provide a fake executable file to copy
        let fakeExe = tmp.appendingPathComponent("fakeBinary")
        try Data("echo".utf8).write(to: fakeExe)
        setenv("DAILY_SHUTDOWN_HOME_OVERRIDE", tmp.path, 1)
        setenv("DAILY_SHUTDOWN_EXECUTABLE_OVERRIDE", fakeExe.path, 1)
        setenv("DAILY_SHUTDOWN_INSTALL_TEST_MODE", "1", 1)

        Installer.install()

        // Check bootstrap command captured
        XCTAssertTrue(installerCapturedCommands.contains { $0.contains("bootstrap gui/") && $0.contains("dev.daily.shutdown.plist") }, "Expected bootstrap command")
        // Validate plist path exists
        let plist = tmp.appendingPathComponent("Library/LaunchAgents/dev.daily.shutdown.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
        // Validate copied binary exists
        let copied = tmp.appendingPathComponent("Library/Application Support/DailyShutdown/bin/DailyShutdown")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }

    func testUninstallRemovesArtifacts() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let launchAgents = tmp.appendingPathComponent("Library/LaunchAgents")
        let binDir = tmp.appendingPathComponent("Library/Application Support/DailyShutdown/bin")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let plist = launchAgents.appendingPathComponent("dev.daily.shutdown.plist")
        let bin = binDir.appendingPathComponent("DailyShutdown")
        try Data("plist".utf8).write(to: plist)
        try Data("bin".utf8).write(to: bin)
        setenv("DAILY_SHUTDOWN_HOME_OVERRIDE", tmp.path, 1)
        setenv("DAILY_SHUTDOWN_INSTALL_TEST_MODE", "1", 1)

        Installer.uninstall()

        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.path))
        // bootout should have been attempted
        XCTAssertTrue(installerCapturedCommands.contains { $0.contains("bootout gui/") })
    }
}
