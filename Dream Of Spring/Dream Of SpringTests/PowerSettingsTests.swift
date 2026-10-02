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
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 0,
            settings: PowerSettings(timeoutSeconds: 600, source: "Battery Power"),
            blockers: [Blocker(pid: 1, identifier: .bundleID("example"), displayName: "Example", reason: "Playback")]))
        let wl = Whitelist(defaults: UserDefaults(suiteName: "SettingsTests." + UUID().uuidString)!)
        let enforcer = SleepEnforcer(whitelist: wl, startAutomatically: false,
            uptime: { sensors.uptime }, readInputs: { sensors.inputs }, requestSleep: { sensors.sleepCalls += 1; return true })
        enforcer.tick()
        #expect(enforcer.configuredTimeoutSeconds == 600)
        sensors.uptime = 120
        sensors.inputs.idleSeconds = 700
        sensors.inputs.settings = nil
        enforcer.tick()
        #expect(sensors.sleepCalls == 0)
        #expect(!enforcer.hasValidSettings)
        #expect(enforcer.powerSource.isEmpty)
        sensors.inputs.settings = PowerSettings(timeoutSeconds: 0, source: "AC Power")
        enforcer.tick()
        #expect(enforcer.hasValidSettings)
        #expect(sensors.sleepCalls == 0)
        sensors.inputs.settings = PowerSettings(timeoutSeconds: 600, source: "AC Power")
        enforcer.tick()
        #expect(sensors.sleepCalls == 1)
    }
}
