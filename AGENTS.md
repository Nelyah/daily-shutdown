## DailyShutdown Architecture (Concise Guide)

### 1. Non‑Negotiable Principles
- SOLID: each file has one reason to change; extend via new protocol conformers, not edits to orchestrator.
- Pure core logic: policy & scheduling decisions produce data only; side-effects isolated at edges.
- Dependency Inversion: controller sees only protocols (`SystemActions`, `AlertPresenting`, `StateStore`, `Clock`, `ShutdownPolicyType`, `Logger`, `TimerFactory`).
- Determinism & Testability: time, timers, system calls, UI abstracted.
- Config Driven: warning timings come solely from `--warn-offsets` (no hard-coded magic numbers in logic).
- Documentation: every public type/function has a doc comment explaining role + invariants.
- Quality Gate: every change has unit tests; commits use Conventional Commit spec.

### 2. Required Practices
1. Write / update unit tests with each functional change.
2. Add doc comments for any new symbol (public or internal if non-trivial).
3. Use Conventional Commits (e.g. `feat:`, `fix:`, `refactor:`, `test:`).
4. New behaviors enter via new protocol implementations; avoid widening existing protocols unless essential.

### 3. Execution Flow
1. `main` parses CLI → `AppConfig` (includes warning offsets list).
2. `ShutdownController` creates or loads `ShutdownState`.
3. `ShutdownPolicy` returns `(shutdownDate, primaryWarningDate?)` (pure).
4. `Scheduler` turns final date + configured offsets into timers via `TimerFactory` & `Clock`.
5. Warning timer → `AlertPresenter` shows alert; user selects postpone / shutdown / ignore.
6. Postpone → policy mutates state (increment + shift) → persist (if enabled) → reschedule.
7. Final timer → `SystemActions.shutdown()` (or dry-run rollover) → new cycle state.

### 4. Components & Roles
- `Config.swift`: Parse CLI -> immutable `AppConfig` (warning offsets, postpone interval, limits, flags).
- `UserPreferences.swift`: Persistent user overrides (daily time, warning offsets) + `ConfigProvider` merging with base config.
- `State.swift`: `ShutdownState` model + persistence (`StateStore` / `FileStateStore`) + `Clock` + `StateFactory` helpers.
- `Policy.swift`: Pure scheduling & postpone rules (`ShutdownPolicyType`). No IO, no timers.
- `Scheduler.swift`: Materializes timers from dates + offsets. Uses `TimerFactory` + `Clock`.
- `TimerFactory` (in `Scheduler.swift`): Creates cancellable one-shot timers (production = GCD, test = mock).
- `AlertPresenter.swift`: UI alert; delegates user decisions.
- `SystemActions.swift`: Encapsulates system shutdown side-effect (AppleScript implementation provided).
- `Logging.swift`: Asynchronous logging via `Logger` protocol.
- `ShutdownController.swift`: Orchestrates, serializes state mutations, invokes policy, scheduler, UI, and system actions.
- `main.swift`: Bootstrap only.

### 5. Project Structure
```
Package.swift
DailyShutdown/
  main.swift
  Config.swift
  State.swift
  Policy.swift
  Scheduler.swift        (includes TimerFactory abstraction)
  AlertPresenter.swift
  SystemActions.swift
  Logging.swift
  ShutdownController.swift
Tests/DailyShutdownTests/
  ShutdownPolicyTests.swift
  PolicyBehaviorTests.swift
  SchedulerTimerFactoryTests.swift
AGENTS.md
README.md
```

### 6. Interaction Graph
`main` → `ShutdownController`
`ShutdownController` → (`StateStore`, `Clock`, `ShutdownPolicyType`, `Scheduler`, `AlertPresenting`, `SystemActions`, `Logger`, config warning offsets)
`Scheduler` → (delegate callbacks to Controller)
`AlertPresenter` → (delegate callbacks to Controller)
`ShutdownPolicy` → (pure; uses state + config + clock date)

### 7. Critical Invariants
- `originalScheduledShutdownISO` immutable per cycle.
- Each postpone strictly increases `scheduledShutdownISO` by configured interval.
- `postponesUsed ≤ effectiveMaxPostpones`.
- Primary warning = shutdownDate - largest warning offset (clamped to now if past).
- Only future offsets yield timers; duplicates excluded.

### 8. Extension Points
- New shutdown mechanism → implement `SystemActions`.
- Alternate UI channel → implement `AlertPresenting`.
- Custom scheduling rules → implement `ShutdownPolicyType` (stay pure).
- Persistence backend → implement `StateStore`.
- Time control → implement `Clock`.
- Alternate timer backend → implement `TimerFactory`.
- Logging sink → implement `Logger`.

### 9. Testing Expectations
- Mock protocols, inject `FixedClock` & mock `TimerFactory` (no sleeps).
- Assert invariants (state progression, timer counts, monotonic schedule, deduped offsets).
- Add tests for any new CLI flags and policy rules.

### 10. Contribution Checklist
1. Define minimal protocol (if needed) & implementation.
2. Add doc comments for new/changed symbols.
3. Add focused unit tests (prefer pure logic isolation).
4. Maintain dependency direction (no cycles).
5. Commit with Conventional Commit message.
6. Update this file ONLY if protocol surface / architecture changes.

### 11. Non-Goals
- Cross-machine sync, multi-user, complex UI flows.

### 12. Summary
Small, documented, protocol-driven components + strict invariants + exhaustive unit tests = safe evolution.

---

---
## 3. Agent Catalog (File → Responsibility → Protocols → Depends On)
| File | Responsibility (SRP) | Provided Protocol(s) | Depends On | Side Effects |
|------|----------------------|----------------------|------------|--------------|
| Config.swift | Parse runtime & compose immutable config | (none public) | Foundation | none |
| State.swift | State model + persistence abstraction + clock | StateStore, Clock | FileManager, JSON | Disk R/W |
| Policy.swift | Pure scheduling & postpone rules | ShutdownPolicyType | StateFactory, AppConfig | none (pure) |
| Scheduler.swift | Timer orchestration | (delegate pattern) | Dispatch | Schedules timers |
| AlertPresenter.swift | User alert UI | AlertPresenting, AlertPresenterDelegate (consumer) | AppKit | Modal dialogs |
| SystemActions.swift | System shutdown execution | SystemActions | Process | Launches external process |
| Logging.swift | Structured async logging | Logger | Dispatch, DateFormatter | stdout writes |
| ShutdownController.swift | Orchestrator / application service | SchedulerDelegate, AlertPresenterDelegate | All above protocols | Coordinates, invokes side effects |
| main.swift | Bootstrap & lifecycle entry point | (none) | AppKit, Controller | Starts run loop |

---
## 4. Dependency Direction (Inversion Strategy)
Outer layer (UI & System) → Controller (application layer) → Policy (domain rules) → State/Config (domain data). Logging is cross-cutting. Concrete implementations sit at edges; Controller consumes only protocols:
- UI edge: `AlertPresenting`
- System edge: `SystemActions`
- Persistence edge: `StateStore`
- Time source: `Clock`
- Domain rule engine: `ShutdownPolicyType`

This allows new implementations (e.g., CLI notifier, different shutdown mechanism) without altering core orchestration.

---
## 5. SOLID Mapping
- S (Single Responsibility): Each file owns one conceptual reason to change.
- O (Open/Closed): Extend by adding new protocol conformers (e.g., `LaunchdSystemActions`) without editing policy/controller.
- L (Liskov): Protocols define minimal, behaviorally consistent contracts; replacements must not weaken guarantees (e.g., `Clock.now()` returns current wall-clock equivalent, not cached values unless documented).
- I (Interface Segregation): Narrow protocols (`SystemActions`, `Clock`, `StateStore`) prevent bloated interfaces.
- D (Dependency Inversion): Controller depends on abstractions. Concrete edges injected via initializer.

---
## 6. Concurrency & Threading Model
- Timers: `Scheduler` runs on its private dispatch queue.
- UI: All alerts dispatched onto main thread inside `AlertPresenter`.
- State Mutation: Serialized through `stateQueue` inside `ShutdownController` to avoid races.
- Logging: Asynchronous emission queue to avoid blocking critical paths.
Guideline: Any new agent mutating shared state must either (a) funnel through `ShutdownController.stateQueue` or (b) introduce its own serialization layer while keeping externally observable operations thread-safe.

---
## 7. State & Persistence Rules
`ShutdownState` invariants:
- `date` matches the cycle creation day (yyyy-MM-dd).
- `scheduledShutdownISO` ≥ creation time.
- `postponesUsed` ≤ `config.effectiveMaxPostpones`.
- `originalScheduledShutdownISO` is immutable reference to the first scheduled time in the cycle.
Persistence is optional (disabled with `--no-persist`). Only persisted after each modifying operation (creation, postpone, cycle rollover). New persistence backends must implement `StateStore` and remain idempotent on save.

---
## 8. Scheduling & Policy Invariants
- Policy is pure: no side effects; deterministic given `(state, config, now)`.
- Postpone: Each apply extends current scheduled time by effective postpone interval.
- Primary warning time = shutdownDate - largest configured warning offset (clamped: if already passed, fires immediately).
- Additional warning offsets (e.g., 900s, 300s, 60s) are derived in `Scheduler` from `config.effectiveWarningOffsets` preserving policy purity.
- If using relative mode (`--in-seconds`), both `scheduledShutdownISO` and `originalScheduledShutdownISO` are that relative future time.

---
## 9. Extension Scenarios
1. Alternate Shutdown Mechanism: Implement `SystemActions` (e.g., use `pmset schedule shutdown`). Inject into controller.
2. Different UI Channel: Implement `AlertPresenting` (e.g., NSStatusItem, notification center, command-line prompt).
3. Custom Policy: New type conforming to `ShutdownPolicyType` (e.g., dynamic postpone cost, escalating warnings). Must keep `plan()` total order of events and not regress invariants.
4. Distributed State: Implement `StateStore` backed by network or keychain. Ensure atomicity & conflict resolution.
5. Testing Time Travel: Inject a test `Clock` returning deterministic times.
6. Observability: Add wrapper logger implementing `Logger` that streams to file or telemetry backend.

---
## 10. Testing Guidelines
Prefer protocol substitution + deterministic clocks.
Recommended test layers:
- Unit: `ShutdownPolicy` postponement math, schedule lead calculations.
- StateFactory: relative vs daily scheduling boundaries across midnight.
- Controller: scenario tests with mock `Scheduler`, `AlertPresenting`, `SystemActions` capturing invocations.
- Concurrency: Ensure no data races when multiple postpone requests happen rapidly (if UI allows).
Mocks should record calls and timestamps; avoid sleeping—advance time via injected `Clock`.

---
## 11. Adding a New Agent (Checklist)
- Define smallest protocol capturing required behavior.
- Provide a concrete implementation in its own file.<PRIVATE>
- Inject via `ShutdownController` initializer parameter (supply a default if commonly used).
- Ensure no direct knowledge of unrelated agents (keep dependency graph acyclic).
- Add tests using a mock conformer.
- Document invariants & side effects in a short header comment.

---
## 12. Error Handling & Reliability
Most current IO (file read/write, process launch) is best-effort. Future enhancement: elevate failures to `Logger.error` with contextual metadata. New agents should:
- Fail fast for programmer errors (precondition / early return).
- Gracefully degrade for environmental issues (log & continue) unless unsafe.

---
## 13. Observability Practices
Use `log()` for notable lifecycle events:
- Scheduling decisions
- Postpone actions
- Shutdown initiation
Do not log sensitive user data. Keep log lines single-line parseable `[timestamp] [LEVEL] message`.

---
## 14. Security & Permissions
The app triggers shutdown through AppleScript (`osascript`). Alternate implementations may require enhanced privileges. Avoid introducing elevated operations inside domain agents; isolate in `SystemActions` implementations. Validate all external command inputs are static or sanitized.

---
## 15. Future Improvements (Backlog Ideas)
- Pluggable warning strategies (multiple escalating alerts) – baseline implemented via configurable offsets list.
- Persistence migration versioning.
- Telemetry integration via new `Logger` conformer.
- Graceful cancel / revoke of scheduled OS-level shutdown (if using system schedulers).
- Configurable business hours or skip days policy.

---
## 16. Glossary
Agent: A focused component behind a protocol boundary.
Cycle: One continuous period culminating in an attempted shutdown.
Plan: Pair of (primaryWarningDate?, shutdownDate) returned by policy.

---
## 17. Quick Reference (Who Talks To Whom)
Controller → (Policy, Scheduler, AlertPresenter, SystemActions, StateStore, Clock, Logger, Config warning offsets)
Scheduler → Controller (callbacks via delegate)
AlertPresenter → Controller (user decisions via delegate)
Policy → (State, Config, Clock.now input only) returns pure value

---
## 18. Non-Goals
- Multi-user session management
- Cross-machine synchronization
- Complex UI flows beyond a single alert prompt

---
## 19. Change Management
Any change that alters protocol contracts should be versioned in this file. When adding a method to a protocol, justify it under SOLID (does it force unrelated implementers to change?). Prefer creation of a new protocol extension over widening an existing one.

Recent notable changes:
- Unified single warning lead into a list of offsets (`--warn-offsets`) eliminating legacy `--warn-seconds`.
- Scheduler now schedules multiple warnings using config-provided offsets.

---
## 20. Summary
This document codifies the agent-oriented, protocol-first, side-effect-at-edges architecture. Follow it to maintain clarity, testability, and principled extensibility.
