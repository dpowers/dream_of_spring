//
//  ActivityTests.swift
//  Dream Of SpringTests
//
import Foundation
import Testing
@testable import Dream_Of_Spring

struct ActivityTests {
    @Test func failedOrIncompleteReadsAreUnknown() {
        #expect(ActivityState.sample(status: -1, value: 0, bytes: 4) == .unknown)
        #expect(ActivityState.sample(status: 0, value: 0, bytes: 0) == .unknown)
        #expect(ActivityState.sample(status: 0, value: 1, bytes: 4) == .active)
        #expect(ActivityState.sample(status: 0, value: 0, bytes: 4) == .inactive)
        #expect(ActivityState.combined([.inactive, .unknown]) == .unknown)
        #expect(ActivityState.combined([.active, .unknown]) == .active)
    }
    @Test func unknownAndActiveSamplesRestartQuietWindow() {
        var clearance = ActivityClearance()
        func permitsSleep(state: ActivityState, uptime: TimeInterval) -> Bool {
            clearance.permitsSleep(state: state, uptime: uptime)
        }
        #expect(!permitsSleep(state: .inactive, uptime: 0))
        #expect(permitsSleep(state: .inactive, uptime: 120))
        #expect(!permitsSleep(state: .unknown, uptime: 121))
        #expect(!permitsSleep(state: .inactive, uptime: 150))
        #expect(!permitsSleep(state: .inactive, uptime: 269))
        #expect(permitsSleep(state: .inactive, uptime: 270))
        #expect(!permitsSleep(state: .active, uptime: 271))
        #expect(!permitsSleep(state: .inactive, uptime: 300))
    }
    @Test func countdownRestartsOnReadFailureAndClockRollback() {
        var clearance = ActivityClearance()
        func permitsSleep(state: ActivityState, uptime: TimeInterval) -> Bool {
            clearance.permitsSleep(state: state, uptime: uptime)
        }
        #expect(!permitsSleep(state: .inactive, uptime: 100))
        #expect(!permitsSleep(state: .inactive, uptime: 190))
        #expect(clearance.remainingSeconds == 30)
        #expect(!permitsSleep(state: .unknown, uptime: 200))
        #expect(clearance.remainingSeconds == 120)
        #expect(!permitsSleep(state: .inactive, uptime: 210))
        #expect(!permitsSleep(state: .inactive, uptime: 10))
        #expect(clearance.remainingSeconds == 120)
        #expect(permitsSleep(state: .inactive, uptime: 130))
        #expect(clearance.remainingSeconds == 0)
    }

    @Test @MainActor func intermittentFailureRemainsVisibleDuringQuietWait() {
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 900,
            settings: PowerSettings(timeoutSeconds: 600, source: "AC Power"),
            blockers: [Blocker(pid: 1, identifier: .bundleID("browser"), displayName: "Browser", reason: "Playback")]))
        let wl = Whitelist(defaults: UserDefaults(suiteName: "ActivityTests." + UUID().uuidString)!)
        let enforcer = SleepEnforcer(whitelist: wl, startAutomatically: false, uptime: { sensors.uptime },
            wallClock: { Date(timeIntervalSince1970: sensors.uptime) },
            readInputs: { sensors.inputs }, requestSleep: { sensors.sleepCalls += 1; return true })
        enforcer.tick()
        sensors.inputs.cameraActivity = .unknown; sensors.uptime = 90; enforcer.tick()
        sensors.inputs.cameraActivity = .inactive; sensors.uptime = 120; enforcer.tick()
        sensors.uptime = 180; enforcer.tick()
        #expect(enforcer.cameraActivity == .inactive)
        #expect(enforcer.captureQuietSecondsRemaining == 60)
        #expect(enforcer.lastCaptureResetReason == "Camera status read failed")
        #expect(enforcer.lastCaptureResetAt == Date(timeIntervalSince1970: 90))
        #expect(enforcer.diagnostics.contains("Camera status read failed"))
        #expect(enforcer.diagnostics.contains("quiet time remaining: 60.0s"))
        #expect(sensors.sleepCalls == 0)
        sensors.uptime = 240; enforcer.tick()
        #expect(!enforcer.isCaptureProtected)
        #expect(sensors.sleepCalls == 1)
    }

    @Test @MainActor func deviceSwitchCannotImmediatelySleep() {
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 900,
            settings: PowerSettings(timeoutSeconds: 600, source: "AC Power"),
            blockers: [Blocker(pid: 1, identifier: .bundleID("browser"), displayName: "Browser", reason: "Playback")],
            microphoneActivity: .active))
        let wl = Whitelist(defaults: UserDefaults(suiteName: "ActivityTests." + UUID().uuidString)!)
        let enforcer = SleepEnforcer(whitelist: wl, startAutomatically: false, uptime: { sensors.uptime },
            readInputs: { sensors.inputs }, requestSleep: { sensors.sleepCalls += 1; return true })
        enforcer.tick()
        sensors.inputs.microphoneActivity = .unknown; sensors.uptime = 30; enforcer.tick()
        sensors.inputs.microphoneActivity = .inactive; sensors.uptime = 60; enforcer.tick()
        sensors.uptime = 179; enforcer.tick()
        #expect(sensors.sleepCalls == 0)
        sensors.inputs.microphoneActivity = .active; sensors.uptime = 180; enforcer.tick()
        sensors.inputs.microphoneActivity = .inactive; sensors.uptime = 210; enforcer.tick()
        sensors.uptime = 330; enforcer.tick()
        #expect(sensors.sleepCalls == 1)
    }
}
