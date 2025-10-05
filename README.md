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

## Configuration

DailyShutdown can be configured via CLI flags, a TOML config file, and (optionally) environment variables to locate that file.

Precedence (highest wins):
1. CLI flags
2. Config file values
3. Built-in defaults

### Config File Location
The loader searches for `config.toml` here:
1. `$XDG_CONFIG_HOME/daily-shutdown/config.toml` if `XDG_CONFIG_HOME` is set and non-empty
2. `~/.config/daily-shutdown/config.toml` (fallback)

Override path (primarily for tests / power users) with:
```
DAILY_SHUTDOWN_CONFIG_PATH=/absolute/path/to/custom.toml swift run DailyShutdown ...
```

Files larger than 256 KB are ignored for safety. Non‑UTF8 files are also ignored (a log line is emitted in both cases).

### Supported TOML Keys
Base (default) parameters:
```
dailyHour = 18                    # 0-23
dailyMinute = 0                   # 0-59
defaultPostponeIntervalSeconds = 900
defaultMaxPostpones = 3
defaultWarningOffsets = [900, 300, 60]   # seconds before shutdown; list deduped & sorted descending
```

Optional runtime option keys (same semantics as CLI; can live in file so you do not have to pass flags):
```
relativeSeconds = 7200            # one-off relative shutdown (seconds from now)
warnOffsets = [1200, 600, 60]     # overrides defaultWarningOffsets for this run
dryRun = true                     # simulate only
noPersist = true                  # disable state persistence
postponeIntervalSeconds = 600     # override effective postpone interval
maxPostpones = 5                  # override maximum postpones per cycle
```

Invalid / out-of-range values are discarded with a logged warning. Offsets <= 0 are removed; duplicates are deduplicated; remaining offsets are sorted high → low.

### Generating / Inspecting Config
Write a starter file (only defaults) to your config directory:
```
mkdir -p ~/.config/daily-shutdown
swift run DailyShutdown print-default-config > ~/.config/daily-shutdown/config.toml
```

Inspect the currently effective merged configuration (after applying file + CLI):
```
swift run DailyShutdown print-config
```

Unset runtime options are shown as commented lines (e.g. `# relativeSeconds = (unset)`).

### Example config.toml
```
# DailyShutdown configuration
dailyHour = 19
dailyMinute = 30
defaultPostponeIntervalSeconds = 900
defaultMaxPostpones = 4
defaultWarningOffsets = [1800, 900, 300, 60]

# Runtime overrides
warnOffsets = [1200, 600, 60]
dryRun = true
postponeIntervalSeconds = 600
maxPostpones = 6
```

Note: If you supply both `warnOffsets` (runtime override) and `defaultWarningOffsets`, the runtime `warnOffsets` list supersedes `defaultWarningOffsets` for warning scheduling, while `defaultWarningOffsets` remains the baseline set.

## Install as LaunchAgent
Install a user LaunchAgent so DailyShutdown starts automatically at login:
```
swift run DailyShutdown install
launchctl load -w ~/Library/LaunchAgents/dev.daily.shutdown.plist
```
Re-run the install command to update the binary / plist (idempotent overwrite). The binary is copied to:
```
~/Library/Application Support/DailyShutdown/bin/DailyShutdown
```
To add arguments (e.g., custom warning offsets), edit the generated plist's `ProgramArguments` array and then:
```
launchctl unload ~/Library/LaunchAgents/dev.daily.shutdown.plist
launchctl load -w ~/Library/LaunchAgents/dev.daily.shutdown.plist
```
View status:
```
launchctl list | grep dev.daily.shutdown || true
```
Remove:
```
launchctl unload ~/Library/LaunchAgents/dev.daily.shutdown.plist
rm ~/Library/LaunchAgents/dev.daily.shutdown.plist
```

## Test
```
swift test
```

## Extend
Create a new type conforming to one of the extension protocols (`SystemActions`, `AlertPresenting`, `ShutdownPolicyType`, `StateStore`, `Clock`, `TimerFactory`, `Logger`) and pass it into the `ShutdownController` initializer. Do not modify existing core logic—extend via new implementations.

## Safety
Use `--dry-run` during development (actual shutdown via AppleScript).
