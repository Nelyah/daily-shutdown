//
//  main.swift
//  DailyShutdown
//
//  Created by Chloé Dequeker on 2025-10-02.
//

import Foundation
import AppKit
import Darwin
// Entry point: responsibilities are now split into separate modules (Config, State, Policy, Scheduler, Alert, SystemActions, Logging).
// This file intentionally contains only startup wiring.

/// Bootstraps application dependencies, parses runtime options, instantiates the controller
/// and enters the main run loop. Designed to keep side effects localized.
func runDailyShutdownApp() {

    let args = CommandLine.arguments.dropFirst()
    if args.contains("--help") || args.contains("-h") {
        print(CommandLineConfigParser.helpText)
        return
    }
    if args.first == "print-default-config" {
        print(CommandLineConfigParser.defaultConfigTOML())
        return
    }
    if args.first == "print-config" {
        // Need to construct config with file + CLI merges (excluding this sub-command token).
        var filtered = CommandLine.arguments
        // Remove the sub-command so parser doesn't treat it as flag.
        if let idx = filtered.firstIndex(of: "print-config") { filtered.remove(at: idx) }
        let config = CommandLineConfigParser.parseWithFile(arguments: filtered)
        print(CommandLineConfigParser.effectiveConfigTOML(config))
        return
    }
    if args.first == "install" {
        Installer.install()
        return
    }
    if args.first == "uninstall" {
        Installer.uninstall()
        return
    }
    // Immediate flush for print output.
    setbuf(stdout, nil)
    setbuf(stderr, nil)

    // Instantiate application (headless accessory).
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let config = CommandLineConfigParser.parseWithFile()
    if config.options.relativeSeconds != nil || config.options.dryRun {
        NSApp.activate(ignoringOtherApps: true)
    }

    let controller = ShutdownController(config: config)
    controller.start()
    RunLoop.main.run()
}

runDailyShutdownApp()
