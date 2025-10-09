# Reminders (Config‑Driven Typed Confirmation) – Design & Implementation Plan

Status: Proposed (pre-implementation)
Author: CodeCompanion
Date: 2025-10-08
Scope: Add a parallel, pure-policy + controller driven subsystem that surfaces recurring confirmation reminders requiring user entry of a predefined text. Fully configuration-driven; no code changes needed to add/remove reminders.

---
## 1. Goals
- Allow multiple independent daily reminders.
- Each reminder repeatedly prompts the user every configurable interval after a configurable daily start time until user enters the required confirmation text.
- Adding/removing/modifying reminders requires only configuration file edits (and optional CLI overrides later).
- Preserve existing shutdown architecture principles: SOLID, dependency inversion, pure policy, side-effects at edges.
- Keep shutdown domain untouched (no protocol widening); implement a parallel domain.

## 2. Non-Goals
- Complex recurrence rules (weekdays/weekends differentiation) – future enhancement.
- Partial match hints, fuzzy matching, or variable confirmation text.
- Cross-day persistence of partial input attempts beyond counts (only completion state needed).
- Unified controller for shutdown + reminders (we keep them separate for SRP).

## 3. Configuration Model (TOML)
```toml
[reminders]

# Each item is a daily reminder definition
[[reminders.items]]
id = "stretch"
startTime = "10:00"              # 24h local time HH:MM
intervalSeconds = 300             # 5 minutes
prompt = "Stretch now. Type DONE to confirm."
requiredText = "DONE"
caseInsensitive = true            # default true if omitted

[[reminders.items]]
id = "water"
startTime = "09:30"
intervalSeconds = 600
prompt = "Drink water. Type HYDRATED."
requiredText = "HYDRATED"
caseInsensitive = false
```
Validation rules:
- id: non-empty, unique.
- startTime: HH:MM -> 0≤HH≤23, 0≤MM≤59.
- intervalSeconds: ≥30 (guard against spam); clamp or warn if > 86400.
- requiredText: non-empty.
- prompt: non-empty.
- caseInsensitive: default true.
Unknown keys ignored with warning (consistent with overall config philosophy).

## 4. Data Structures
```swift
struct ReminderConfig: Equatable {
    struct Item: Equatable {
        let id: String
        let startHour: Int
        let startMinute: Int
        let intervalSeconds: Int
        let prompt: String
        let requiredText: String
        let caseInsensitive: Bool
    }
    let items: [Item]
}

struct ReminderRuntimeState: Codable, Equatable {
    let date: String                // yyyy-MM-dd (local)
    var completions: Set<String>    // ids completed today
    var lastFireISO: [String:String]// id -> last fire ISO8601
}
```

## 5. Protocols (Abstractions)
```swift
protocol ReminderStateStore {
    func load() -> ReminderRuntimeState?
    func save(_ state: ReminderRuntimeState)
}

protocol ReminderPolicyType {
    /// Pure calculation of next fire date for one reminder, else nil if completed.
    func nextFire(for item: ReminderConfig.Item,
                  state: ReminderRuntimeState,
                  now: Date) -> Date?
}

protocol ReminderScheduling: AnyObject {
    func schedule(id: String, at date: Date)
    func cancel(id: String)
    func cancelAll()
}

protocol ReminderPresenterDelegate: AnyObject {
    func reminderUserSubmitted(id: String, text: String)
    func reminderUserIgnored(id: String)
}

protocol ReminderPresenting: AnyObject {
    var delegate: ReminderPresenterDelegate? { get set }
    func present(model: ReminderAlertModel)
}

struct ReminderAlertModel {
    let id: String
    let prompt: String
    let caseInsensitive: Bool
    // requiredText intentionally NOT exposed to UI for security/anti-gaming (optional design choice)
}
```

(Where feasible, reuse existing `Clock`, `Logger`, and `TimerFactory`).

## 6. Pure Policy Logic
Deterministic rules:
1. If item.id ∈ state.completions → return nil.
2. Compute today's start Date from (hour, minute) using injected `Clock`.
3. If now < start → next = start.
4. Let last = parsed lastFireISO[item.id] (only valid if same day).
5. If now ≥ start and last == nil → immediate fire (now) to avoid waiting full interval after app start.
6. Else next = last + intervalSeconds.
7. If computed next ≤ now (possible if clock advanced) → next = now (fire ASAP, not negative scheduling).

Pure function pseudocode:
```swift
func nextFire(item, state, now): Date? {
    if state.completions.contains(item.id) { return nil }
    let start = todayAt(hour:item.startHour, minute:item.startMinute, now: now)
    if now < start { return start }
    let last = parseISO(state.lastFireISO[item.id])
    guard let last else { return now }
    let candidate = last.addingTimeInterval(TimeInterval(item.intervalSeconds))
    return candidate > now ? candidate : now
}
```

## 7. ReminderController Responsibilities
- Initialize / rollover state (reset if date changed).
- For each config item: compute `nextFire` and schedule.
- On timer firing for id:
  - Update `lastFireISO[id] = nowISO`.
  - Persist.
  - Present `ReminderAlertModel`.
- On user submit:
  - Compare input vs requiredText (apply case strategy, trim whitespace).
  - If matches: add to completions, cancel id's future timers.
  - Persist.
  - (Optional) schedule next day rollover check.
- On ignore: do nothing (policy will schedule next by virtue of lastFire updated) → recompute & schedule single next.
- At midnight (detect via date mismatch on any event): reset state & reschedule all.

Serialization: Use internal `DispatchQueue` (e.g. `reminderQueue`) to guard state + scheduling.

## 8. Scheduling Strategy
Implement `ReminderScheduler`:
- Maintains `[String: Timer]` map.
- Uses shared `TimerFactory` to create one-shot timers.
- `schedule(id:at:)` cancels existing timer for id first.
- `cancel(id:)` / `cancelAll()` for cleanup.

No modification to existing shutdown `Scheduler.swift` to keep concerns isolated.

## 9. UI Layer
`ReminderAlertPresenter` (AppKit):
- Similar pattern to `AlertPresenter` but with NSTextField for input.
- Buttons: "Submit" (default), "Ignore" (alternate). Maybe ESC maps to Ignore.
- On Submit: delegate callback with entered string.
- No dynamic countdown needed; periodicity handled by timers.
- (Optional) subtle feedback on incorrect submission (beep + shake) before closing OR just close and rely on next popup.
Design choice: Close window after incorrect entry (simpler). This keeps logic stateless.

## 10. Matching Logic
```swift
func matches(expected: String, input: String, caseInsensitive: Bool) -> Bool {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if caseInsensitive { return expected.lowercased() == trimmed.lowercased() }
    return expected == trimmed
}
```

## 11. Persistence
Separate file: `RemindersState.json` in same directory pattern used by existing state (respect `--no-persist` from shutdown if you want a unified toggle; else introduce `--no-reminder-persist`).
`ReminderStateStore` file implementation mirrors `FileStateStore` (JSON, atomic write).

## 12. Day Rollover Handling
At each timer fire or periodic (e.g. schedule a midnight timer) check if `state.date != todayString(clock.now())`:
- Reset to new `ReminderRuntimeState(date: today, completions: [], lastFireISO: [:])`.
- Cancel all timers.
- Rescan & schedule all `nextFire`.

## 13. Error & Edge Cases
- If user edits config during runtime: (initial pass) require restart; future enhancement: watch file & rescan.
- Invalid interval or start time: log warning and skip that reminder.
- Duplicate id: log warning; keep first definition only.

## 14. Testing Plan
1. Policy Tests
   - Pre-start returns start.
   - Immediate fire after start with no last.
   - Interval scheduling increments properly.
   - Completion suppresses scheduling.
2. Controller Tests (using mock scheduler + presenter)
   - Fire triggers presentation & state update.
   - Correct submission cancels further scheduling for that id.
   - Incorrect submission leads to reschedule (next interval).
   - Day rollover resets completions.
3. Config Parsing Tests
   - Valid config loads items.
   - Invalid hour/minute rejected with warning.
   - Duplicate IDs produce single entry.
4. Matching Tests
   - Case insensitive vs sensitive comparisons.
5. Persistence Tests
   - Save/load cycle retains completions & lastFire.
6. Concurrency Test
   - Rapid submit & ignore events are serialized (state remains consistent).

Mocks Needed: `MockClock`, `MockReminderScheduler`, `MockReminderPresenter`, `InMemoryReminderStateStore`, `TestLogger`.

## 15. Incremental Implementation Steps
1. Parse reminder config section (no controller yet). Tests: parsing & validation.
2. Add runtime state + memory + file stores. Tests: persistence round trip.
3. Implement pure `ReminderPolicy`. Tests: policy scenarios.
4. Add `ReminderScheduler` (simple tests for schedule/cancel idempotence).
5. Implement `ReminderController` with mocks. Tests: fire → present → submit flows.
6. Add `ReminderAlertPresenter` (no heavy tests; just text building if factored).
7. Wire into `main.swift`: instantiate after config load; call `start()`.
8. Documentation & README/TOML example update.

## 16. Integration with Existing App
In `main.swift` after existing controller bootstrap:
```swift
let reminderController = ReminderController(config: reminderConfig,
                                           clock: clock,
                                           policy: ReminderPolicy(),
                                           stateStore: reminderStateStore,
                                           scheduler: ReminderScheduler(timerFactory: timerFactory, clock: clock),
                                           presenter: ReminderAlertPresenter(),
                                           logger: logger,
                                           persistEnabled: !config.noPersist)
reminderController.start()
```
Shared dependencies: `clock`, `timerFactory`, `logger` (inject for consistency).

## 17. Visibility & API Surface
All new symbols internal. Rationale: Feature is internal to the binary; no third-party modules consuming them. Upholds minimal public surface principle. Justification required only if future external API emerges.

## 18. Logging
Log (info level):
- Reminder scheduled (id, nextFireISO).
- Reminder fired (id, nowISO).
- Submission success/failure (NOT the user-entered text to avoid leaking; only success boolean).
- Completion recorded (id).
- Day rollover reset.
Log (warn level): config validation issues / duplicate IDs.

## 19. Security & Privacy
- Do not log user-entered text verbatim.
- Required phrase is already in config; minimal exposure. Optionally omit requiredText from UI model if you want UX to rely purely on prompt.

## 20. Future Enhancements (Backlog)
- Weekday include/exclude lists.
- Max ignore count escalation (shorter intervals or stronger alerts).
- Alternative delivery channels (Notification Center, menu bar item).
- Telemetry counters (reminder completion latency).
- Per-reminder postpone (snooze) button with limited uses.

## 21. Risks & Mitigations
| Risk | Mitigation |
|------|------------|
| Timer drift across sleep | On wake (existing or future wake event), recompute nextFire using policy. |
| User edits system clock backward | Policy always uses now; might cause immediate refire; acceptable for v1. |
| Many reminders congest UI | Stagger if multiple fire same instant (queue; present sequentially). |
| Modal interruption fatigue | Future: switch to non-blocking panel or notification. |

## 22. Summary
A parallel, pure-policy driven reminders subsystem fits cleanly into existing architecture without widening shutdown protocols. Configuration-only extensibility is achieved via TOML arrays. Clear separation keeps SRP intact while reusing shared abstractions for time, timers, and logging.

---
## 23. Open Questions (To Confirm Before Implementing)
- Close reminder window on incorrect input (current assumption) vs keep open until correct? (Default: close.)
- Show remaining attempts? (Not in MVP.)
- Should `--no-persist` also disable reminder persistence? (Recommended: yes, reuse flag.)

(Decide these before coding Step 5.)
