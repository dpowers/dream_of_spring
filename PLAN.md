# Dream Of Spring — Implementation Plan

A planning document for v1 of the menu-bar app described in `CLAUDE.md`.
Written before any product code exists; the source tree is still the unmodified
Xcode 26 SwiftUI template.

The goal of this document is to (a) lock in the small number of architectural
decisions whose cost compounds if we get them wrong, (b) lay out an
implementation order that keeps the app working at every step, and (c) name
the unknowns explicitly so we know what to spike before committing.

---

## 1. Product behaviour, restated precisely

The user has configured a system-sleep timeout via System Settings → Battery /
Energy Saver (or `pmset` directly). Other processes register
`IOPMAssertion`s that suppress that timeout indefinitely. The user wants the
configured timeout honoured regardless.

Concretely, Dream Of Spring will:

1. Read the user's currently-active **system-sleep timeout** from IOKit power
   preferences (the value of the `System Sleep Timer` key, in minutes, for the
   currently providing power source). Call this `T`.
2. Periodically observe **real user idle time** (`I`) and the set of
   sleep-blocking assertions held system-wide. Loose cadence — within a
   minute of the right time is fine; this is not a real-time system.
3. When `I ≥ T` **and** at least one **non-whitelisted** process holds a
   `PreventUserIdleSystemSleep` assertion **and** the system is still awake,
   request system sleep via `IOPMSleepSystem`. This is the same primitive
   `pmset sleepnow` uses; it overrides idle-prevent assertions by design.
4. Do nothing when the user has configured "Never sleep" (`T = 0`), or when
   the only assertions blocking sleep belong to whitelisted apps, or when no
   assertions are blocking — the system is already going to sleep on its own.

**Per-app whitelist:** the user can mark specific apps (by bundle identifier,
falling back to process name) as allowed to keep the Mac awake. Whitelisted
processes' assertions are ignored when deciding whether to act. The list is
persisted in `UserDefaults` and edited from the menu — see §3.3.

**Out of scope for v1** (called out so they don't creep in):

- Display sleep enforcement (only `PreventUserIdleSystemSleep`, not the
  display variant).
- Forcing sleep on demand ("sleep now" button).
- Scheduled sleep windows ("force sleep between 11pm and 7am").
- Wake-from-sleep policy.

## 2. Architectural decisions

Two decisions worth pinning down before writing code.

### 2.1 App Sandbox: **OFF**, single-process app, no helper

This is a personal-use utility — no MAS distribution goal. So:

- Turn off `ENABLE_APP_SANDBOX` on the app target. This unblocks the IOKit
  user-client open that `IOPMSleepSystem` needs and removes the only reason
  we'd need an `SMAppService.daemon` privileged helper.
- Hardened Runtime can stay on or off; for personal use it doesn't matter.
  Leaving it on costs nothing and keeps the option of distributing to a
  friend's Mac later without re-engineering.
- A regular user-process call to `IOPMSleepSystem` is exactly what `pmset
  sleepnow` does, and that runs without `sudo`. No helper needed.

### 2.2 Force-sleep mechanism: **`IOPMSleepSystem`**, not killing offenders

The naïve impulse is to terminate processes holding assertions. Don't:

- The `pmset` snapshot on this very Mac shows `powerd` itself holding
  `PreventUserIdleSystemSleep` ("Prevent sleep while display is on"). Killing
  Apple system daemons is a non-starter.
- Only the owning process can release its own assertion. There is no IOKit
  call that lets us release someone else's.
- `IOPMSleepSystem` is precisely the override that "sleep now" uses — it
  treats `PreventUserIdleSystemSleep` as advisory rather than blocking,
  because the request is no longer idle-driven.

So: read the assertions for *display purposes only* (we tell the user who's
blocking sleep), and use `IOPMSleepSystem` as the actuator.

## 3. Module shape

Keep the v1 layout flat. No premature dependency injection, no protocols
where a struct will do. All on `MainActor` (matches the project's
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).

```
Dream Of Spring/
├── Dream_Of_SpringApp.swift     @main, MenuBarExtra, owns SleepEnforcer
├── SleepEnforcer.swift          The loop: read → decide → act
├── PowerInfo.swift              Pure IOKit reads (assertions, prefs, idle)
├── SleepActuator.swift          Wraps IOPMSleepSystem; mockable seam
├── Whitelist.swift              UserDefaults-backed Set<AppIdentifier>
├── Decider.swift                Pure function: state → Action (testable)
└── MenuContent.swift            SwiftUI for the menu bar dropdown
```

**Why split `Decider` out:** the IOKit calls are hard to unit-test, but the
*policy* (when to act given idle/timeout/assertions/last-action) is the part
most likely to grow bugs. Keeping it as a pure function with a struct input
makes it trivially testable with Swift Testing.

**Why split `SleepActuator` out:** so tests can swap in a no-op actuator and
assert the decider asked for sleep, without actually putting the test machine
to sleep.

### 3.1 The decider's contract

```swift
struct EnforcerSnapshot {
    var idleSeconds: TimeInterval
    var configuredTimeoutSeconds: TimeInterval   // 0 means "never"
    var nonWhitelistedBlockerCount: Int           // PreventUserIdleSystemSleep, post-whitelist
    var secondsSinceLastSleepAttempt: TimeInterval
    var isPaused: Bool
}

enum EnforcerAction { case doNothing, requestSleep }

func decide(_ s: EnforcerSnapshot) -> EnforcerAction
```

Rules:

- `isPaused` → `.doNothing`.
- `configuredTimeoutSeconds == 0` → `.doNothing` (user wants no idle sleep).
- `nonWhitelistedBlockerCount == 0` → `.doNothing` (either nothing's blocking,
  or the only blockers are whitelisted — system will sleep on its own).
- `idleSeconds < configuredTimeoutSeconds + grace` → `.doNothing` (small
  buffer so we don't fire a hair before the OS would have).
- `secondsSinceLastSleepAttempt < cooldown` → `.doNothing` (don't loop on a
  failed sleep attempt).
- otherwise → `.requestSleep`.

Constants for v1 (tunable later, no UI):

- `grace = 15s` — small buffer so we don't pre-empt the OS by a fraction.
- `cooldown = 120s` — if a sleep attempt didn't take, wait two minutes
  before trying again. Cheap, and minute-accuracy is fine.

### 3.2 The loop

A **30-second** `Timer` on `MainActor`. Each tick:

1. Build an `EnforcerSnapshot` (calls into `PowerInfo` and `Whitelist`).
2. Run `decide(_:)`.
3. If `.requestSleep`: log, call `SleepActuator.sleep()`, record timestamp.
4. Publish the snapshot for the UI (an `@Observable` on `SleepEnforcer`).

30 s tick + 15 s grace = ≤ 45 s worst-case latency past the configured
timeout; comfortably within the "minute or so" tolerance and cheap on the
battery. The IOKit reads are cheap (cached CFDictionaries, not IOService
opens), so this is essentially free.

### 3.3 Whitelist

Identity model: each blocking process has an `AppIdentifier`, derived from
the pid via `NSRunningApplication(processIdentifier:)`:

- Prefer `bundleIdentifier` (e.g. `com.vivaldi.Vivaldi`).
- Fall back to executable name (e.g. `sharingd`) for processes without a
  bundle.

```swift
enum AppIdentifier: Hashable, Codable {
    case bundleID(String)
    case processName(String)
}

@MainActor final class Whitelist: ObservableObject {
    @Published private(set) var entries: Set<AppIdentifier>
    func contains(_ id: AppIdentifier) -> Bool
    func toggle(_ id: AppIdentifier)
    // Persists to UserDefaults under "whitelistedApps".
}
```

UI: each "blocking sleep" row in the menu has a toggle next to it ("Allow
this app to keep the Mac awake"). A separate "Manage whitelist…" item opens
a small popover listing all current entries with a remove button — for
removing apps that aren't currently running.

## 4. Implementation phases

Each phase ends with the app in a runnable, demonstrable state. Land in this
order — don't skip ahead, because the early phases are cheap and surface
issues that change later work.

### Phase 0 — Project shape (no behaviour yet)

- Replace `WindowGroup { ContentView() }` with `MenuBarExtra("Dream Of Spring", systemImage: "moon.zzz") { Text("Hello") }`.
- Add `INFOPLIST_KEY_LSUIElement = YES` to the app target's build settings
  (Debug + Release). Don't hand-author an `Info.plist` — the project uses
  `GENERATE_INFOPLIST_FILE = YES`.
- Set `ENABLE_APP_SANDBOX = NO` on the app target (Debug + Release).
- Delete the placeholder `ContentView.swift` (or repurpose).
- Add a `Dream Of Spring.entitlements` if needed, but don't anticipate —
  first see what's actually rejected.

**Done when:** `xcodebuild build` succeeds, launching the app shows a moon
icon in the menu bar, no Dock icon, no window.

### Phase 1 — Read everything

Implement `PowerInfo` with three pure read functions and exercise them in the
menu UI as plain debug text. No decision-making, no actions yet.

- `PowerInfo.userIdleSeconds()` — wraps
  `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, .any)`.
- `PowerInfo.activeSystemSleepTimeoutSeconds()` —
  `IOPMCopyPMPreferences()` keyed by the active power source from
  `IOPSGetProvidingPowerSourceType(IOPSCopyPowerSourcesInfo()…)`. Returns 0
  for "Never". Read the `kIOPMSystemSleepKey` value, multiply by 60.
- `PowerInfo.blockingAssertions()` —
  `IOPMCopyAssertionsByProcess()` filtered to entries where assertion type ==
  `kIOPMAssertionTypePreventUserIdleSystemSleep` and level ==
  `kIOPMAssertionLevelOn`. Return `[Blocker]` where:
  ```swift
  struct Blocker {
      let pid: pid_t
      let identifier: AppIdentifier   // bundle ID if available, else process name
      let reason: String              // assertion's "name" key, for display
  }
  ```
  pid → `AppIdentifier` mapping uses `NSRunningApplication(processIdentifier:)`.

The menu shows:

```
Idle: 12s
Timeout: 600s (AC)
Blocking sleep:
  • sharingd — Handoff
  • Vivaldi — WebRTC has active PeerConnections
─────────────
Quit
```

This is the "X-ray" build — already useful, and it surfaces every API issue
before any actuation logic exists.

**Done when:** the menu correctly mirrors `pmset -g assertions` and `pmset
-g`, on both AC and battery.

### Phase 2 — Decide (pure)

Add `Whitelist` (UserDefaults-backed) and `Decider.decide(_:)`, with unit
tests covering:

- Paused → no-op.
- `T = 0` → no-op even with blockers.
- No blockers → no-op even past timeout.
- Past timeout + blockers, none whitelisted → `.requestSleep`.
- Past timeout + blockers, **all whitelisted** → no-op.
- Past timeout + blockers, some whitelisted some not → `.requestSleep`.
- Recently attempted → no-op (cooldown).
- Just under timeout → no-op (grace).

Wire it into the loop but route `.requestSleep` to a logging stub, not the
real actuator. Surface the would-be action in the menu ("Would force sleep
in: 23s").

**Done when:** unit tests pass, manually inducing the conditions
(e.g. `caffeinate -i` in a terminal, lower `pmset sleep` to 1 min) shows the
menu transition through "would force sleep" without the machine actually
sleeping.

### Phase 3 — Act

Implement `SleepActuator.sleep()`:

```swift
let port = IOPMFindPowerManagement(kIOMainPortDefault)
defer { IOServiceClose(port) }
let kr = IOPMSleepSystem(port)
```

Log the kern_return on failure. That's it.

Wire the loop's `.requestSleep` to the real actuator. Add a "Pause / Resume"
menu item and a "Pause for 1 hour" option (writes `isPaused` and a
re-enable-at timestamp into the enforcer).

**Done when:** with `caffeinate -i -t 600 &` running and `pmset sleep` at 1
min, the Mac actually sleeps ~30s after the configured timeout. Wake. Verify
the assertion is still held but the Mac slept anyway.

### Phase 4 — Polish for daily use

- **Whitelist UI.** Per-blocker toggle in the menu (Phase 1's read-only list
  becomes interactive); separate "Manage whitelist…" popover for entries
  whose owning app isn't currently running.
- **Status icon variants.** Three states:
  - Disabled / paused → `moon.zzz` outlined.
  - Active, nothing (non-whitelisted) blocking → `moon.zzz`.
  - Active, non-whitelisted blockers present → `moon.zzz.fill` (or a subtle badge).
- **"Open Energy Saver settings"** menu item — `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.battery")!)`.
- **Launch at login** via `SMAppService.mainApp.register()` with a toggle.
- **About** entry, version from `CFBundleShortVersionString`.
- A simple **`os_log`-based** log so we can post-mortem failed sleep attempts.
  Subsystem `art.gardenplanner.dream-of-spring`, category `enforcer`.

**Done when:** running in normal daily use for a few days produces no
surprises and the menu reflects state correctly.

### Phase 5 — Install for daily use

Personal use, so no notarisation/DMG/Sparkle. Just:

- Build a Release configuration: `xcodebuild -configuration Release`.
- Copy `Dream Of Spring.app` to `/Applications` (or `~/Applications`).
- Re-register Launch-at-Login if the path moved.

Replace with the real version each time something meaningful changes.

## 5. Risks and unknowns to spike

These are the things I'd want to verify with a 30-minute experiment **before**
committing to the architecture above. None of them are likely to flip the
plan, but each is plausible enough that "I assumed" answers aren't enough.

### 5.1 Does `IOPMSleepSystem` really work from a regular user process under Hardened Runtime?

`pmset sleepnow` works without root, so the underlying call is user-callable.
But `pmset` is Apple-signed; Hardened Runtime might gate this for third-party
binaries. **Spike:** a 20-line Swift CLI that calls `IOPMSleepSystem`,
codesigned with Hardened Runtime, run from Terminal. If it sleeps the Mac,
we're done. If it returns `kIOReturnNotPrivileged`, fall back to a helper.

### 5.2 Display-sleep timing relative to system-sleep timing

If the user has `displaysleep > sleep` (unusual but legal), `powerd` holds
`PreventUserIdleSystemSleep` *itself* until display sleep. Our policy would
fire and force-sleep the system before the display naturally went off. That's
arguably correct — the user asked for system sleep at `T` minutes — but it's
worth verifying the behaviour is sane on real hardware (does the display
turn off as part of system sleep? yes, but confirm).

### 5.3 Multiple power sources / power-source switches

The user can change power source mid-session (unplug a laptop). `T` should
re-read on each tick — cheap, just don't cache it across ticks.

### 5.4 Sleep that doesn't take

`IOPMSleepSystem` returns success but the system stays awake (e.g. a kernel
`PreventSystemSleep` assertion from a USB device). The cooldown handles this:
we log the failure, wait 60s, try again. We do *not* escalate to anything
weirder. If a kernel-level driver wants the Mac awake, the user should
suspect their hardware, not Dream Of Spring.

## 6. Test strategy

- **Unit tests (Swift Testing):** `Decider` only. ~10 cases, fast, no IOKit.
- **Integration check (manual, scripted):** a `make test-live` (or
  equivalent) that sets `pmset sleep` to a low value, spawns
  `caffeinate -i -t 300`, launches the app, and uses `log stream
  --predicate 'subsystem == "art.gardenplanner.dream-of-spring"'` to confirm
  the trigger fires. Doesn't run in CI; runs on the dev machine before each
  release.
- **No UI tests for v1.** UI is a static menu and a couple of toggles. The
  XCTest UI target stays in the project but unused; revisit if the menu grows
  meaningfully.

## 7. Open questions for the user

1. **Pause durations.** Plan has Pause / Pause-for-1-hour / Resume. Is
   there a different default set you'd want (e.g. 15min / 1hr /
   until-tomorrow-morning)?
2. **Menu icon.** `moon.zzz` is a fine placeholder; speak up now if you have
   a stronger preference.
3. **"Never sleep" behaviour.** When `pmset` says "never", I'd have the app
   sit dormant with a menu line explaining why, on the theory that a
   silently-inactive menu-bar app is more confusing than a chatty one. OK?

Everything else I'd just decide and ship; happy to revisit if any of those
defaults look wrong.
