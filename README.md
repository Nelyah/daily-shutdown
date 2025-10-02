# DailyShutdown

macOS utility: schedule daily or relative shutdown with staged warnings & postpones. See `AGENTS.md` for architecture.

## Run
```
swift run DailyShutdown [options]
```
Options:
```
--in-seconds N    Relative shutdown (seconds from now)
--warn-offsets L  Warning offsets list (e.g. "900,300,60")
--postpone-sec S  Postpone interval seconds
--max-postpones K Max postpones
--dry-run         Simulate only (no shutdown)
--no-persist      Do not save state
```
Example:
```
swift run DailyShutdown --in-seconds 3600 --warn-offsets "900,300,60" --postpone-sec 600 --max-postpones 2 --dry-run
```

## Test
```
swift test
```

## Extend
Implement a protocol (`SystemActions`, `AlertPresenting`, `ShutdownPolicyType`, `StateStore`, `Clock`, `TimerFactory`, `Logger`) and inject via `ShutdownController`.

## Safety
Use `--dry-run` during development (actual shutdown via AppleScript).
