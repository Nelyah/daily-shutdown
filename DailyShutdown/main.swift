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

public func runDailyShutdownApp() {
    // Immediate flush for print output.
    setbuf(stdout, nil)
    setbuf(stderr, nil)

    // Instantiate application (headless accessory).
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let config = CommandLineConfigParser.parse()
    if config.options.relativeSeconds != nil || config.options.dryRun {
        NSApp.activate(ignoringOtherApps: true)
    }

    let controller = ShutdownController(config: config)
    controller.start()
    RunLoop.main.run()
}

runDailyShutdownApp()
