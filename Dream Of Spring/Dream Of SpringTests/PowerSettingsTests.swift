//
//  PowerSettingsTests.swift
//  Dream Of SpringTests
//
import Foundation
import Testing
@testable import Dream_Of_Spring

struct PowerSettingsTests {
    @Test func changingPowerSourcesInvalidatesTimeout() {
        #expect(PowerSettings.validated(timeout: 60, sourceBefore: "Battery Power", sourceAfter: "AC Power") == nil)
        #expect(PowerSettings.validated(timeout: 60, sourceBefore: nil, sourceAfter: nil) == nil)
        #expect(PowerSettings.validated(timeout: nil, sourceBefore: "AC Power", sourceAfter: "AC Power") == nil)
        #expect(PowerSettings.validated(timeout: -1, sourceBefore: "AC Power", sourceAfter: "AC Power") == nil)
    }
    @Test @MainActor func failedReadCannotEnforceOldTimeoutAndRecovers() {
        var inputs = EnforcerReadings(idleSeconds: 0,
            settings: PowerSettings(timeoutSeconds: 600, source: "Battery Power"),
            blockers: [Blocker(pid: 1, identifier: .bundleID("example"), displayName: "Example", reason: "Playback")])
        var calls = 0
        let wl = Whitelist(defaults: UserDefaults(suiteName: "SettingsTests." + UUID().uuidString)!)
        let enforcer = SleepEnforcer(whitelist: wl, startAutomatically: false,
            readInputs: { inputs }, requestSleep: { calls += 1; return true })
        enforcer.tick()
        #expect(enforcer.configuredTimeoutSeconds == 600)
        inputs.idleSeconds = 700
        inputs.settings = nil
        enforcer.tick()
        #expect(calls == 0)
        #expect(!enforcer.hasValidSettings)
        #expect(enforcer.powerSource.isEmpty)
        inputs.settings = PowerSettings(timeoutSeconds: 0, source: "AC Power")
        enforcer.tick()
        #expect(enforcer.hasValidSettings)
        #expect(calls == 0)
        inputs.settings = PowerSettings(timeoutSeconds: 600, source: "AC Power")
        enforcer.tick()
        #expect(calls == 1)
    }
}
