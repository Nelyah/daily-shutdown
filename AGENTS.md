# AGENTS.md

Authoritative guide to the autonomous (agent-style) components of the DailyShutdown application. This document explains roles, boundaries, collaboration patterns, and extension guidelines following SOLID principles.

---
## 1. Purpose & Scope
DailyShutdown schedules a daily (or relative) system shutdown with user warnings and controlled postpones. The codebase is intentionally decomposed into small, substitutable "agents" (objects behind protocols) to:
- Enable safe extension without modifying core logic (Open/Closed)
- Isolate responsibilities (Single Responsibility)
- Invert volatile dependencies (Dependency Inversion)
- Support mocking for tests (Liskov + Interface Segregation)
- Keep side-effects at the edges (system shutdown, UI, disk persistence)

---
## 2. High-Level Flow (Narrative)
1. main.swift builds configuration and instantiates `ShutdownController`.
2. Controller creates/loads state for the current shutdown cycle.
3. Policy derives a schedule plan (primary warning + final times).
4. Scheduler sets dispatch timers (primary + additional configured warning offsets).
5. When warning timer fires, AlertPresenter prompts the user.
6. User action may trigger postpone (state mutation + reschedule) or immediate shutdown.
7. Shutdown executes via `SystemActions`, then a new cycle state is prepared.

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
