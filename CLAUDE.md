# Dream Of Spring

A **menu-bar–only** macOS app that enforces the user's own sleep settings by
neutralising power-management assertions registered by other processes.
It also lets the user grant individual programs permission to continue with
the lid closed, only while they hold an active system-sleep assertion. The user's Energy Saver / Battery
"sleep when inactive for…" preference is the source of truth; Dream Of Spring's
job is to make sure that timer actually fires.

Normal enforcement respects the user's configured idle timeout. The menu also
provides **Sleep Now**, which releases closed-lid protection before requesting
sleep and suspends reactivation until the next hardware input.

## Closed-lid protection

Under **App policies** (or a current blocker), enable **Allow keeping awake with
lid closed**. Permissions persist separately from whitelist policies; existing
whitelists never gain this permission automatically. **Only on external power**
defaults to on and can be disabled per program. An allowed program must hold an
active `PreventUserIdleSystemSleep` or legacy `NoIdleSleepAssertion`. Merely
running, display-sleep assertions, capture and meeting detection do not qualify.
App helpers inherit the containing app's identity. Standalone programs and
backup daemons can be selected by their exact resolved executable path; these
additional rows do not broaden ordinary forced-sleep enforcement.

`ClosedLidPreferences` stores permissions; `ClosedLidPolicy` determines eligibility.
Permission plus an assertion vetoes ordinary enforcement, but never the battery
deadline. Missing lid, battery or assertion readings release protection. With
saved permissions, lightweight assertion/battery/input polling runs every two
seconds; expensive power-settings and capture reads stay at thirty seconds.
Check the menu for active protection before closing the lid.

Actual lid-close suppression uses the privileged `LidHelper` daemon, registered
automatically at normal app startup via `SMAppService`; there is no separate
support switch. macOS still requires approval in System Settings → General →
Login Items. The menu shows an approval action only while that system permission
is pending, and picks up approval changes during polling even without an active
assertion. Startup does not automatically open Settings. The helper's
`BundleProgram` and Mach service plist are embedded in
the app by `scripts/build-lid-helper.sh` and signed before the enclosing app.
Both XPC peers check the signing identity/team; the helper accepts only the
console user's signed app and exposes fixed operations, not arbitrary commands.

Public idle assertions do not override lid closure. The helper uses `pmset -a
disablesleep` for a renewable lease of at most ten seconds. This is a system-wide
override: **use Dream Of Spring's Sleep Now while protection is active**, since
the ordinary Apple-menu sleep request can be suppressed. Screens can still sleep.
The helper checks battery protection independently, drops protection on power
source changes and critical thermal state, and restores sleep on disconnect,
expiry, termination and startup recovery. A durable root-owned journal under
`/var/db/art.gardenplanner.Dream-Of-Spring` records ownership before setting the
override. Existing sleep-disable settings belonging to another utility are
rejected. Concurrent utilities writing the same global flag cannot be reliably
distinguished and should not be used together.

Sleep requests wait for the helper to acknowledge restoration; failed restoration
is retried and shown in the menu. Helper cleanup is independent of the existing
120-second sleep retry cooldown. Automated tests inject the helper transport and
power-setting backend and never change the real sleep setting. Physical lid-close
behavior, on AC and battery with no external monitor, requires a manual hardware
check; a successful setting write alone is not proof of continued execution.

Battery reserve protection is an explicit exception. It is enabled by default
with a 20% reserve target (configurable from 15–30% in the menu). On internal
battery power, the default maximum times without human input are:

- Above 20%, through 30%: 30 minutes, shortened by estimated time to the reserve.
- Above 10%, through 20%: 10 minutes.
- Above 5%, through 10%: 3 minutes.
- At or below 5%: 1 minute.

Changing the reserve shifts the first two bands; the 10% and 5% emergency bands
stay fixed. The reserve is a best-effort target, not a guaranteed charge floor.
Adaptive estimates retain at least ten minutes of utility after interaction.
They require three minutes of charge samples and a drop of at least one point;
the faster of the recent three-minute and rolling ten-minute rates wins. Charge
increases, external power, missing data, and gaps over 90 seconds reset the
estimate. Within an unattended episode an estimate can only tighten a deadline.

These limits override Never, pauses, whitelist policies, capture, meeting
protection, and the absence of visible app assertions. Shorter normal sleep
deadlines still apply. Disabling protection or switching to AC restores normal
rules. An unavailable battery reading suppresses the override until recovery.
`BatteryPreferences` persists the switch and target; `BatteryProtection` owns
the pure budget, drain estimator, and human-activity tracker.

Hardware input counts and idle durations come from Quartz's HID event-state
table, without event taps or reading key contents. The battery timer uses a
continuous monotonic clock that includes sleep. While the app runs, only a new
hardware input count renews the allowance; background wake and HID idle-counter
resets cannot do so. This distinguishes ordinary synthetic session events, not
malicious software impersonating hardware. Remote-control tools may report
input differently. Normal enforcement still uses the existing HIDIdleTime.

The last minute shows a nonactivating warning panel over other applications.
Keyboard/pointer input dismisses it and renews the allowance. It adds no grace:
startup or a charge drop past an already-expired deadline can request sleep
immediately. Power-source notifications and wake notifications trigger fresh
reads; full polling runs every 30 seconds, with lightweight battery/input polls
each second during the warning. The existing 120-second actuator retry cooldown
still applies if macOS does not stay asleep. Tests never invoke the real actuator.

The implementation in v1 follows the phases described in `PLAN.md`. App
Sandbox is **off** (personal-use, not Mac App Store); the actuator calls
`IOPMSleepSystem` directly from the GUI process. Only the optional closed-lid
override uses the privileged helper described above.

## Layout

The Xcode project lives one directory below the repo root and the path
contains spaces, so always quote it.

```
dream_of_spring/                          ← repo root (this file)
└── Dream Of Spring/                      ← Xcode project root
    ├── Dream Of Spring.xcodeproj
    ├── Dream Of Spring/                  ← app target sources
    │   ├── Dream_Of_SpringApp.swift      ← @main, AppKit status item, dynamic icon
    │   ├── SleepEnforcer.swift           ← @Observable; 30s poll loop, decision + actuation
    │   ├── PowerInfo.swift               ← IOKit reads (idle, assertions) + pmset shell-out
    │   ├── CaptureActivity.swift         ← camera/mic in-use reads (CoreMediaIO + CoreAudio)
    │   ├── SleepActuator.swift           ← IOPMSleepSystem wrapper
    │   ├── Decider.swift                 ← pure: snapshot → action (unit-tested)
    │   ├── Whitelist.swift               ← UserDefaults-backed Set<AppIdentifier>
    │   ├── LaunchAtLogin.swift           ← SMAppService wrapper
    │   ├── MenuContent.swift             ← native menu snapshot built on opening
    │   └── Assets.xcassets
    ├── Dream Of SpringTests/             ← Swift Testing (`import Testing`, `@Test`)
    └── Dream Of SpringUITests/           ← XCTest UI tests
```

Source folders use Xcode's **file-system synchronized groups**
(`PBXFileSystemSynchronizedRootGroup`). Drop new `.swift` files into the right
folder and Xcode picks them up — do **not** hand-edit `project.pbxproj` to
register sources.

The status menu uses an AppKit `NSMenu` populated in `menuWillOpen`. Keep its
items stable during tracking: reactive rebuilds from the sleep monitor can
dismiss nested submenus. Status text and checkmarks refresh on the next opening;
actions read current model state, and monitoring continues while the menu is
open. The status icon observes the model separately from the menu.

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
- **Versioning:** calver — the "Stamp version with build date" run-script
  phase overwrites `CFBundleShortVersionString` with the build date
  (`YYYY-MM-DD`) and `CFBundleVersion` with `YYYY.MM.DD` (macOS allows only
  period-separated integers in that key). The phase runs every build
  (`alwaysOutOfDate`), and because it mutates the generated Info.plist,
  every build re-processes the plist and re-signs the app — a no-change
  rebuild is never a no-op; accepted cost, don't try to optimize it away
  with a write-on-change guard (the plist gets reset to the placeholders
  each build, so the guard never converges). The `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` build settings never ship, but they seed the
  generated Info.plist's version keys that the stamp's `Set` requires —
  deleting them fails the build. The menu shows the version as "Version …"
  above Quit.
- **Tests:** unit target uses Swift Testing (`#expect`, `@Test`); UI target uses XCTest. Run with `xcodebuild … test -only-testing:"Dream Of SpringTests"` to skip the slower UI tests.
- **Logging subsystem:** `art.gardenplanner.dream-of-spring`. Stream with `log stream --predicate 'subsystem == "art.gardenplanner.dream-of-spring"'`.

## How the app actually works (mental model)

The system already knows *when* the Mac should sleep (the user's configured
idle timeout from System Settings → Battery / Energy Saver). The problem
Dream Of Spring solves is that other processes register `IOPMAssertion`s
that suppress that timer indefinitely. The app:

1. Polls every **30 s** on `MainActor` (single `Task` loop in `SleepEnforcer`).
2. Each tick, builds an `EnforcerSnapshot` and runs the pure `Decider.decide(_:)`.
   Any camera or microphone in active use anywhere on the system is a
   **global veto** — call apps (FaceTime, Meet, Zoom) hold their keep-awake
   assertions via daemons (`avconferenced`, `coreaudiod`) that never appear
   in the blocker list, so the whitelist cannot protect a live call; the
   capture veto does.
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
- **Camera in use:** CoreMediaIO — enumerate `kCMIOHardwarePropertyDevices`,
  check `kCMIODevicePropertyDeviceIsRunningSomewhere` on each.
- **Microphone in use:** CoreAudio per-process objects —
  `kAudioHardwarePropertyProcessObjectList` +
  `kAudioProcessPropertyIsRunningInput` (macOS 14+). Deliberately *not*
  `kAudioDevicePropertyDeviceIsRunningSomewhere`, which false-positives on
  combo input/output devices (AirPods, USB headsets) during playback-only
  use. Neither read triggers a TCC camera/mic permission prompt.
- **Run-state hardcoded keys** (because Swift's IOKit import drops the CFSTR
  macros): `"AssertType"`, `"AssertLevel"`, `"AssertName"`,
  `"PreventUserIdleSystemSleep"`. See `PowerInfo.swift` for the canonical list.

### What is *intentionally not* handled

- Display sleep itself — not enforced. Display assertions are included in
  ordinary blocker detection because they transitively prevent system idle
  sleep, but they never qualify for closed-lid protection.
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
