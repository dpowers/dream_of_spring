//
//  SleepDeadlineTests.swift
//  Dream Of SpringTests
//
import Foundation
import Testing
@testable import Dream_Of_Spring

@MainActor struct SleepDeadlineTests {
    private func whitelist() -> Whitelist {
        Whitelist(defaults: UserDefaults(suiteName: "SleepDeadlineTests." + UUID().uuidString)!)
    }
    private func decide(idle: Double, deadline: Double?) -> EnforcerAction {
        Decider.decide(EnforcerSnapshot(idleSeconds: idle, configuredTimeoutSeconds: 600,
            hasActiveBlocker: deadline != nil, isCaptureActive: false,
            secondsSinceLastSleepAttempt: 9999, isPaused: false, enforcementDeadlineSeconds: deadline))
    }
    @Test func alwaysAllowedAppVetoesOtherBlockers() {
        let wl = whitelist()
        wl.setPolicy(.alwaysAllow, for: .bundleID("meeting"))
        let deadline = wl.sleepDeadline(for: [.bundleID("meeting"), .bundleID("browser")], configuredTimeout: 600)
        #expect(deadline == .infinity)
        #expect(decide(idle: 10000, deadline: deadline) == .doNothing)
    }
    @Test func longestExtensionWinsAndIncludesDisplayedGrace() {
        let wl = whitelist()
        wl.setPolicy(.allowUpTo(seconds: 1800), for: .bundleID("meeting"))
        wl.setPolicy(.allowUpTo(seconds: 900), for: .bundleID("browser"))
        let deadline = wl.sleepDeadline(for: [.bundleID("meeting"), .bundleID("browser"), .bundleID("other")], configuredTimeout: 600)
        #expect(deadline == 1815)
        #expect(decide(idle: 1800, deadline: deadline) == .doNothing)
        #expect(decide(idle: 1814, deadline: deadline) == .doNothing)
        #expect(decide(idle: 1815, deadline: deadline) == .requestSleep)
    }
    @Test func inactiveWhitelistEntryDoesNotPreventSleep() {
        let wl = whitelist()
        wl.setPolicy(.alwaysAllow, for: .bundleID("closed"))
        let deadline = wl.sleepDeadline(for: [.bundleID("browser")], configuredTimeout: 600)
        #expect(deadline == 615)
        #expect(decide(idle: 615, deadline: deadline) == .requestSleep)
        #expect(wl.sleepDeadline(for: [], configuredTimeout: 600) == nil)
    }
}
