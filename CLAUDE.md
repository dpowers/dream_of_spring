# Dream Of Spring

A **menu-bar–only** macOS app that enforces the user's own sleep settings by
neutralising power-management assertions registered by other processes.
Conceptually the inverse of Amphetamine: rather than preventing sleep, it
prevents *other apps from preventing sleep*. The user's Energy Saver / Battery
"sleep when inactive for…" preference is the source of truth; Dream Of Spring's
job is to make sure that timer actually fires.

It is **not** a "sleep now" button. The user's configured idle timeout is
respected — the app only steps in when that timeout has elapsed and something
else is keeping the Mac awake.

The implementation in v1 follows the phases described in `PLAN.md`. App
Sandbox is **off** (personal-use, not Mac App Store); the actuator calls
`IOPMSleepSystem` directly from the GUI process — no privileged helper.

## Layout

The Xcode project lives one directory below the repo root and the path
contains spaces, so always quote it.

```
dream_of_spring/                          ← repo root (this file)
└── Dream Of Spring/                      ← Xcode project root
    ├── Dream Of Spring.xcodeproj
    ├── Dream Of Spring/                  ← app target sources
    │   ├── Dream_Of_SpringApp.swift      ← @main, MenuBarExtra scene, dynamic icon
    │   ├── SleepEnforcer.swift           ← @Observable; 30s poll loop, decision + actuation
    │   ├── PowerInfo.swift               ← IOKit reads (idle, assertions) + pmset shell-out
    │   ├── SleepActuator.swift           ← IOPMSleepSystem wrapper
    │   ├── Decider.swift                 ← pure: snapshot → action (unit-tested)
    │   ├── Whitelist.swift               ← UserDefaults-backed Set<AppIdentifier>
    │   ├── LaunchAtLogin.swift           ← SMAppService wrapper
    │   ├── MenuContent.swift             ← SwiftUI for the menu bar dropdown
    │   └── Assets.xcassets
    ├── Dream Of SpringTests/             ← Swift Testing (`import Testing`, `@Test`)
    └── Dream Of SpringUITests/           ← XCTest UI tests
```

Source folders use Xcode's **file-system synchronized groups**
(`PBXFileSystemSynchronizedRootGroup`). Drop new `.swift` files into the right
folder and Xcode picks them up — do **not** hand-edit `project.pbxproj` to
register sources.

## Build & test

Run from `Dream Of Spring/` (the directory containing `.xcodeproj`):

```sh
# Build
xcodebuild -project "Dream Of Spring.xcodeproj" -scheme "Dream Of Spring" build

# Unit + UI tests (macOS, no destination needed for a Mac-only app)
xcodebuild -project "Dream Of Spring.xcodeproj" -scheme "Dream Of Spring" test

# Run the built app
open "$(xcodebuild -project 'Dream Of Spring.xcodeproj' -scheme 'Dream Of Spring' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Dream Of Spring.app"
```

## Project settings worth knowing

- **Bundle ID:** `art.gardenplanner.Dream-Of-Spring`
- **Deployment target:** macOS 26.0 — feel free to use the latest SwiftUI / Observation / Swift Concurrency APIs
- **Swift:** 5.0 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (everything is MainActor unless explicitly opted out via `nonisolated` or another global actor). Pure value types and pure functions are marked `nonisolated` (e.g. `Decider`, `EnforcerSnapshot`, `EnforcerAction`) to keep them callable from tests and Sendable contexts.
- **App Sandbox:** **OFF** (`ENABLE_APP_SANDBOX = NO`). Required so `IOPMSleepSystem` can open an IOKit user-client to `IOPMrootDomain`. Do not re-enable without first introducing a privileged helper.
- **`LSUIElement`:** ON via `INFOPLIST_KEY_LSUIElement = YES` — no Dock icon, no app menu, menu-bar only.
- **Hardened Runtime:** ON
- **Tests:** unit target uses Swift Testing (`#expect`, `@Test`); UI target uses XCTest. Run with `xcodebuild … test -only-testing:"Dream Of SpringTests"` to skip the slower UI tests.
- **Logging subsystem:** `art.gardenplanner.dream-of-spring`. Stream with `log stream --predicate 'subsystem == "art.gardenplanner.dream-of-spring"'`.

## How the app actually works (mental model)

The system already knows *when* the Mac should sleep (the user's configured
idle timeout from System Settings → Battery / Energy Saver). The problem
Dream Of Spring solves is that other processes register `IOPMAssertion`s
that suppress that timer indefinitely. The app:

1. Polls every **30 s** on `MainActor` (single `Task` loop in `SleepEnforcer`).
2. Each tick, builds an `EnforcerSnapshot` and runs the pure `Decider.decide(_:)`.
3. If the decider says `.requestSleep`, calls `SleepActuator.sleepNow()`,
   which is `IOPMFindPowerManagement` + `IOPMSleepSystem` — the same path
   `pmset sleepnow` uses. This sleep request overrides
   `PreventUserIdleSystemSleep` assertions because it's user-initiated, not
   idle-driven.
4. After firing, a 120 s cooldown suppresses retry. A 15 s grace window past
   the configured timeout absorbs measurement skew between the OS and our
   `HIDIdleTime` read.

Worst-case latency past the configured timeout: poll (≤30 s) + grace (15 s)
= ~45 s. Within the "minute or so" tolerance.

### IOKit surface used

- **Configured system-sleep timer:** shells out to `pmset -g`, parses the
  `sleep` line. `IOPMCopyPMPreferences` is **not** surfaced in the Swift
  IOKit module on macOS 26 — don't try to call it. (`pmset -g` already
  resolves to the active power source for us.)
- **Real user idle time:** `IOHIDSystem` registry property `HIDIdleTime`
  (nanoseconds). Robust; no `CGEventType.any` enum-cast hazards.
- **Who is holding sleep awake:** `IOPMCopyAssertionsByProcess`, filtered to
  `PreventUserIdleSystemSleep` with level > 0.
- **Force sleep:** `IOPMFindPowerManagement(kIOMainPortDefault)` →
  `IOPMSleepSystem(port)` → `IOServiceClose(port)`.
- **Run-state hardcoded keys** (because Swift's IOKit import drops the CFSTR
  macros): `"AssertType"`, `"AssertLevel"`, `"AssertName"`,
  `"PreventUserIdleSystemSleep"`. See `PowerInfo.swift` for the canonical list.

### What is *intentionally not* handled

- `PreventUserIdleDisplaySleep` (display sleep) — out of scope; only system
  sleep is enforced.
- `PreventSystemSleep` (kernel / I/O subsystem) — the sleep request can fail
  here; we log and back off via the cooldown rather than escalating.
- Releasing other processes' assertions — only the owning process can; we
  don't try.
- Killing offending processes — `powerd` itself holds
  `PreventUserIdleSystemSleep` ("Prevent sleep while display is on"), so any
  kill-the-offenders approach would fight macOS itself.

## Conventions

- Pure value types and pure functions live as `nonisolated` to opt out of
  the project's MainActor default — this keeps them callable from tests and
  Sendable contexts.
- Match the Xcode template's file header comment style for new Swift files
  (the `//  Filename.swift` block at the top) — it keeps diffs against
  Xcode-generated files clean.
- Keep the Swift Testing style for unit tests (`import Testing`, `@Test func …`),
  not XCTest, unless the test specifically needs XCTest features.
- IOKit string-key constants are hardcoded in `PowerInfo.swift` rather than
  imported from headers — Swift's IOKit module is inconsistent about which
  `kIOPM*Key` constants it surfaces across SDK versions.
