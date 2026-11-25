//
//  BlockerStatusTests.swift
//  Dream Of SpringTests
//

import Testing
@testable import Dream_Of_Spring

struct BlockerStatusTests {
    private func status(policy: Bool = true, deadline: Double? = 315, idle: Double = 0,
                        participates: Bool = true, lid: Bool = false, battery: Double? = nil) -> BlockerStatus {
        BlockerStatus.evaluate(participatesInEnforcement: participates, hasPolicy: policy,
            deadline: deadline, idleSeconds: idle, closedLidProtected: lid, batteryRemainingSeconds: battery)
    }

    @Test func unlistedAppIsOverridden() {
        #expect(status(policy: false, deadline: 315, idle: 0) == .overridden)
    }

    @Test func alwaysAllowHasNoLimitUnlessBatteryCaps() {
        #expect(status(deadline: .infinity) == .keepingAwake(remainingSeconds: nil, reason: .alwaysAllowed))
        #expect(status(deadline: .infinity, battery: 120) == .keepingAwake(remainingSeconds: 120, reason: .alwaysAllowed))
    }

    @Test func allowUpToCountsDownThenIsOverridden() {
        #expect(status(deadline: 915, idle: 315) == .keepingAwake(remainingSeconds: 600, reason: .allowedUpTo))
        #expect(status(deadline: 915, idle: 315, battery: 60) == .keepingAwake(remainingSeconds: 60, reason: .allowedUpTo))
        #expect(status(deadline: 915, idle: 915) == .overridden)
    }

    @Test func expiredBatteryAllowanceOverridesEverything() {
        #expect(status(deadline: .infinity, lid: true, battery: 0) == .overridden)
    }

    @Test func closedLidAndStandaloneProgramsKeepAwake() {
        #expect(status(policy: false, lid: true) == .keepingAwake(remainingSeconds: nil, reason: .closedLid))
        #expect(status(policy: false, participates: false) == .keepingAwake(remainingSeconds: nil, reason: .notEnforced))
    }
}
