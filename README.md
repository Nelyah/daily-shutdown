# DailyShutdown

DailyShutdown is a macOS utility that schedules a daily (or relative) system shutdown with user warnings and limited postpones. Architecture follows SOLID with small protocol-backed "agents" (see `AGENTS.md`).

## Features
- Configurable shutdown time (daily) or relative `--in-seconds` mode
- Multiple staged warning alerts (configurable offsets via `--warn-offsets`)
- Postpone with configurable interval & maximum count
- Dry-run mode for testing without shutting down
- Persistent state (disable via `--no-persist`)
- Extensible via protocol abstractions (UI, system actions, persistence, clock, policy, logging)

## Repository Layout
```
DailyShutdown/           # Source (executable target)
Tests/DailyShutdownTests # XCTest unit tests
AGENTS.md                # Architectural / agent documentation
Package.swift            # SwiftPM manifest
README.md                # This file
```

## Requirements
- macOS 13+
- Swift 5.9 toolchain (Xcode 15 or later / SwiftPM compatible)

## Building (Swift Package Manager)
Clone the repository then:
```
swift build
```
The executable binary will be at:
```
.swiftpm/build/debug/DailyShutdown
```
(or `release` if you pass `-c release`).

### Run
```
swift run DailyShutdown [options]
```

### Common Options
```
--in-seconds N          Schedule shutdown N seconds from now (relative mode)
--warn-offsets LIST     Comma or space separated seconds before shutdown for staged warnings (e.g. "900,300,60")
--postpone-sec S        Postpone interval in seconds
--max-postpones K       Maximum number of postpones in a cycle
--dry-run               Do not actually shut down; roll to next cycle instead
--no-persist            Do not save state to disk
```

Example:
```
swift run DailyShutdown --in-seconds 3600 --warn-offsets "900,300,60" --postpone-sec 600 --max-postpones 2 --dry-run
```

## Building (Xcode)
You can open the package directly:
```
xed .
```
Xcode will treat it as a Swift Package project. Use the scheme `DailyShutdown` to build & run.

## Tests
Run all tests:
```
swift test
```
Or inside Xcode use Product > Test (⌘U).

### Test Focus
- Policy calculations & postpone logic
- Config parsing (including warning offsets)
- Controller orchestration (with mocks)
- Scheduler multi-warning behavior (future enhancement: abstract timers for deterministic testing)

## Extending
See `AGENTS.md` for details. Add new behavior by introducing a new protocol conformer rather than modifying existing orchestrator logic.

## Safety / Disclaimer
Invoking real shutdown uses AppleScript (`osascript`). Use `--dry-run` while iterating to avoid unintentionally closing your session.

## License
(Insert license information here.)

---
Generated README for initial developer setup. Improvements welcome.
