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
    @Test @MainActor func deviceSwitchCannotImmediatelySleep() {
        var inputs = EnforcerReadings(idleSeconds: 900,
            settings: PowerSettings(timeoutSeconds: 600, source: "AC Power"),
            blockers: [Blocker(pid: 1, identifier: .bundleID("browser"), displayName: "Browser", reason: "Playback")],
            microphoneActivity: .active)
        var time: TimeInterval = 0
        var calls = 0
        let wl = Whitelist(defaults: UserDefaults(suiteName: "ActivityTests." + UUID().uuidString)!)
        let enforcer = SleepEnforcer(whitelist: wl, startAutomatically: false, uptime: { time },
            readInputs: { inputs }, requestSleep: { calls += 1; return true })
        enforcer.tick()
        inputs.microphoneActivity = .unknown; time = 30; enforcer.tick()
        inputs.microphoneActivity = .inactive; time = 60; enforcer.tick()
        time = 179; enforcer.tick()
        #expect(calls == 0)
        inputs.microphoneActivity = .active; time = 180; enforcer.tick()
        inputs.microphoneActivity = .inactive; time = 210; enforcer.tick()
        time = 330; enforcer.tick()
        #expect(calls == 1)
    }
}
