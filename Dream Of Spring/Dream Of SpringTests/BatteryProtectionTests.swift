//
//  BatteryProtectionTests.swift
//  Dream Of SpringTests
//

import Foundation
import AppKit
import Testing
@testable import Dream_Of_Spring

struct BatteryStateTests {
    @Test func thresholdsAndExternalPower() {
        for (percentage, expected): (Double, TimeInterval?) in [
            (100, nil), (30.01, nil), (30, 1800), (20.01, 1800), (20, 600),
            (19, 600), (10.01, 600), (10, 180), (5.01, 180), (5, 60), (0, 60)
        ] {
            #expect(BatteryState(percentage: percentage, isOnBatteryPower: true).idleLimitSeconds() == expected)
            #expect(BatteryState(percentage: percentage, isOnBatteryPower: false).idleLimitSeconds() == nil)
        }
        #expect(BatteryState(percentage: 40, isOnBatteryPower: true).idleLimitSeconds(reserve: 30) == 1800)
        #expect(BatteryState(percentage: 29, isOnBatteryPower: true).idleLimitSeconds(reserve: 30) == 600)
    }

    @Test func capacityValidation() {
        #expect(BatteryState.validated(currentCapacity: 50, maxCapacity: 500, isOnBatteryPower: true)?.percentage == 10)
        for (current, maximum) in [(0.0, 0.0), (-1, 100), (101, 100), (.nan, 100), (10, .infinity)] {
            #expect(BatteryState.validated(currentCapacity: current, maxCapacity: maximum, isOnBatteryPower: true) == nil)
        }
    }

    @Test(arguments: [60.0, 180.0, 600.0, 1800.0], [false, true])
    func overridesAllVetoesAtExactDeadline(limit: Double, blocked: Bool) {
        var snapshot = EnforcerSnapshot(idleSeconds: 0, configuredTimeoutSeconds: 0,
            hasActiveBlocker: blocked, isCaptureActive: true, secondsSinceLastSleepAttempt: 9999,
            isPaused: true, enforcementDeadlineSeconds: .infinity, isMeetingProtected: true,
            batteryIdleSeconds: limit - 0.01, batteryIdleLimitSeconds: limit)
        #expect(Decider.decide(snapshot) == .doNothing)
        snapshot.batteryIdleSeconds = limit
        #expect(Decider.decide(snapshot) == .requestSleep)
        snapshot.batteryIdleSeconds = 0
        #expect(Decider.decide(snapshot) == .doNothing)
        snapshot.batteryIdleSeconds = limit
        snapshot.secondsSinceLastSleepAttempt = 119
        #expect(Decider.decide(snapshot) == .doNothing)
        snapshot.secondsSinceLastSleepAttempt = 120
        #expect(Decider.decide(snapshot) == .requestSleep)
    }
}

struct BatteryBudgetTests {
    private func battery(_ percentage: Double, onBattery: Bool = true) -> BatteryState {
        BatteryState(percentage: percentage, isOnBatteryPower: onBattery)
    }

    @Test func estimateRequiresHistoryAndResetsOnGapsChargingAndRecalibration() {
        var estimator = BatteryDrainEstimator()
        for second in stride(from: 0, through: 150, by: 30) {
            estimator.sample(battery(30 - Double(second) / 60), now: Double(second))
        }
        #expect(estimator.percentagePointsPerHour == nil)
        estimator.sample(battery(27), now: 180)
        #expect(estimator.percentagePointsPerHour == 60)
        estimator.sample(battery(26), now: 400)
        #expect(estimator.percentagePointsPerHour == nil, "Sleeping or missing samples invalidates the rate")
        estimator.sample(battery(26, onBattery: false), now: 430)
        #expect(estimator.percentagePointsPerHour == nil)
        for second in stride(from: 460, through: 640, by: 30) {
            estimator.sample(battery(26 - Double(second - 460) / 60), now: Double(second))
        }
        #expect(estimator.percentagePointsPerHour == 60)
        estimator.sample(battery(25), now: 670)
        #expect(estimator.percentagePointsPerHour == nil, "An upward recalibration cannot be treated as negative consumption")
    }

    @Test func roundedFlatReadingsDoNotInventAnEstimate() {
        var estimator = BatteryDrainEstimator()
        for second in stride(from: 0, through: 600, by: 30) {
            estimator.sample(battery(25), now: Double(second))
        }
        #expect(estimator.percentagePointsPerHour == nil)
    }

    @Test func oneRoundedPointOverAShortSpanIsNotARate() {
        var estimator = BatteryDrainEstimator()
        for second in stride(from: 0, through: 510, by: 30) {
            estimator.sample(battery(second < 180 ? 25 : 24), now: Double(second))
        }
        #expect(estimator.percentagePointsPerHour == nil)
        estimator.sample(battery(24), now: 540)
        #expect(abs((estimator.percentagePointsPerHour ?? 0) - 1.0 / 540 * 3600) < 0.001)
        estimator.sample(battery(23), now: 570)
        #expect(abs((estimator.percentagePointsPerHour ?? 0) - 2.0 / 570 * 3600) < 0.001)
    }

    @Test func helperFallsBackToRegistryIdleWithoutEventCounters() {
        #expect(PowerSafetyReadings.daemonActivity(count: 0, eventIdle: 900, registryIdle: 3).count == nil)
        #expect(PowerSafetyReadings.daemonActivity(count: 0, eventIdle: 900, registryIdle: 3).idle == 3)
        #expect(PowerSafetyReadings.daemonActivity(count: 0, eventIdle: 900, registryIdle: nil).idle == 900)
        let live = PowerSafetyReadings.daemonActivity(count: 7, eventIdle: 4, registryIdle: 3)
        #expect(live.count == 7 && live.idle == 4)
    }

    @Test func fastDrainShortensBudgetButSlowingDownCannotExtendIt() {
        var protection = BatteryProtection()
        for second in stride(from: 0, through: 180, by: 30) {
            protection.update(battery: battery(30 - Double(second) / 60), idle: Double(second),
                inputCount: 1, now: Double(second), enabled: true, reserve: 20)
        }
        #expect(protection.drainPerHour == 60)
        #expect(protection.plan?.idleLimitSeconds == 600, "Reserve would be reached at ten minutes")
        #expect(protection.plan?.reason == .approachingReserve)
        for second in stride(from: 210, through: 570, by: 30) {
            protection.update(battery: battery(27), idle: Double(second),
                inputCount: 1, now: Double(second), enabled: true, reserve: 20)
        }
        #expect(protection.plan?.idleLimitSeconds == 600)
        #expect(protection.plan?.remainingSeconds == 30)
        #expect(protection.plan?.shouldWarn == true)
        protection.update(battery: battery(27), idle: 0, inputCount: 2, now: 571, enabled: true, reserve: 20)
        #expect((protection.plan?.idleLimitSeconds ?? 0) > 600, "Actual input grants a fresh allowance")
        #expect(protection.plan?.shouldWarn == false)
    }

    @Test func acceleratedWorkloadUsesRecentRate() {
        var estimator = BatteryDrainEstimator()
        for second in stride(from: 0, through: 600, by: 30) {
            let charge = second <= 420 ? 40 - Double(second) / 600 : 39.3 - Double(second - 420) / 60
            estimator.sample(battery(charge), now: Double(second))
        }
        #expect(abs((estimator.percentagePointsPerHour ?? 0) - 60) < 0.001)
    }

    @Test func hardwareInputResetsBudgetButAnIdleCounterResetDoesNot() {
        var protection = BatteryProtection()
        protection.update(battery: battery(9), idle: 100, inputCount: 10, now: 100, enabled: true, reserve: 20)
        protection.resetDrainEstimate()
        protection.update(battery: battery(9), idle: 0, inputCount: 10, now: 1000, enabled: true, reserve: 20)
        #expect(protection.plan?.idleSeconds == 1000)
        #expect(protection.plan?.remainingSeconds == 0)
        protection.update(battery: battery(9), idle: 0, inputCount: 11, now: 1001, enabled: true, reserve: 20)
        #expect(protection.plan?.remainingSeconds == 180)
        #expect(protection.plan?.shouldWarn == false)
    }

    @Test func warningsStayInsideBudgetAndThresholdDropsDoNotGrantExtraTime() {
        var protection = BatteryProtection()
        protection.update(battery: battery(10), idle: 119, inputCount: 1, now: 119, enabled: true, reserve: 20)
        #expect(protection.plan?.shouldWarn == false)
        protection.update(battery: battery(10), idle: 120, inputCount: 1, now: 120, enabled: true, reserve: 20)
        #expect(protection.plan?.shouldWarn == true)
        #expect(protection.plan?.remainingSeconds == 60)
        protection.update(battery: battery(5), idle: 121, inputCount: 1, now: 121, enabled: true, reserve: 20)
        #expect(protection.plan?.remainingSeconds == 0)
        #expect(protection.plan?.shouldWarn == false)
    }

    @Test func externalPowerMissingDataAndDisableRemoveOverride() {
        for replacement: BatteryState? in [battery(5, onBattery: false), nil] {
            var protection = BatteryProtection()
            protection.update(battery: battery(5), idle: 55, inputCount: 1, now: 55, enabled: true, reserve: 20)
            #expect(protection.plan?.shouldWarn == true)
            protection.update(battery: replacement, idle: 56, inputCount: 1, now: 56, enabled: true, reserve: 20)
            #expect(protection.plan == nil)
        }
        var protection = BatteryProtection()
        protection.update(battery: battery(5), idle: 100, inputCount: 1, now: 100, enabled: false, reserve: 20)
        #expect(protection.plan == nil)
    }
}

@MainActor
struct BatteryProtectionTests {
    @Test func warningPanelCannotTakeFocusAndHidesWhenCancelled() throws {
        let controller = BatteryWarningController()
        defer { controller.hide() }
        controller.update(plan: BatteryPlan(idleSeconds: 120, idleLimitSeconds: 180, reason: .lowBattery),
                          battery: BatteryState(percentage: 9, isOnBatteryPower: true), reserve: 20)
        let panel = try #require(NSApp.windows.last(where: { $0.title == "Battery reserve protection" }))
        #expect(panel.isVisible)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        controller.update(plan: nil, battery: nil, reserve: 20)
        #expect(!panel.isVisible)
    }

    private func makeEnforcer(_ sensors: TestSensors) -> SleepEnforcer {
        let defaults = UserDefaults(suiteName: "BatteryTests." + UUID().uuidString)!
        return SleepEnforcer(whitelist: Whitelist(defaults: defaults),
            batteryPreferences: BatteryPreferences(defaults: defaults),
            startAutomatically: false, uptime: { sensors.uptime }, readInputs: { sensors.inputs },
            requestSleep: { sensors.sleepCalls += 1; return true })
    }

    @Test func batteryDropOverridesPauseFailedSettingsAndActiveCalls() {
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 599, settings: nil, blockers: [],
            cameraActivity: .unknown, microphoneActivity: .active, meetingActivity: .active,
            battery: BatteryState(percentage: 19, isOnBatteryPower: true)))
        let enforcer = makeEnforcer(sensors)
        enforcer.pause(for: nil)
        enforcer.tick()
        #expect(sensors.sleepCalls == 0)
        #expect(enforcer.batteryIdleLimitSeconds == 600)
        sensors.inputs.battery = BatteryState(percentage: 10, isOnBatteryPower: true)
        enforcer.tick()
        #expect(sensors.sleepCalls == 1)
        #expect(enforcer.batteryIdleLimitSeconds == 180)
        #expect(enforcer.isPaused)
        #expect(enforcer.diagnostics.contains("idle cap: 180.0s"))
    }

    @Test(arguments: [WhitelistPolicy.alwaysAllow, .allowUpTo(seconds: 7200)])
    func whitelistAndLongSystemTimerCannotExtendCap(policy: WhitelistPolicy) {
        let blocker = Blocker(pid: 1, identifier: .bundleID("player"), displayName: "Player", reason: "Playing")
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 1790,
            settings: PowerSettings(timeoutSeconds: 7200, source: "Battery Power"), blockers: [blocker],
            battery: BatteryState(percentage: 25, isOnBatteryPower: true)))
        let enforcer = makeEnforcer(sensors)
        enforcer.whitelist.setPolicy(policy, for: blocker.identifier)
        enforcer.tick()
        #expect(enforcer.nextPollSeconds == 1)
        #expect(enforcer.batteryIdleLimitSeconds == 1800)
        #expect(enforcer.batteryPlan?.shouldWarn == true)
        sensors.uptime = 10
        sensors.inputs.idleSeconds = 1800
        enforcer.tick()
        #expect(sensors.sleepCalls == 1)
        #expect(enforcer.activeBlockers.count == 1)
    }

    @Test func shorterNormalDeadlineStillApplies() {
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 0,
            settings: PowerSettings(timeoutSeconds: 60, source: "Battery Power"),
            blockers: [Blocker(pid: 1, identifier: .bundleID("player"), displayName: "Player", reason: "Playing")],
            battery: BatteryState(percentage: 19, isOnBatteryPower: true)))
        let enforcer = makeEnforcer(sensors)
        enforcer.tick()
        sensors.uptime = 120
        sensors.inputs.idleSeconds = 120
        enforcer.tick()
        #expect(enforcer.sleepDeadlineSeconds == 75)
        #expect(sensors.sleepCalls == 1)
    }

    @Test func warningDoesNotPromiseMoreTimeThanNormalSettingsAllow() {
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 0,
            settings: PowerSettings(timeoutSeconds: 120, source: "Battery Power"),
            blockers: [Blocker(pid: 1, identifier: .bundleID("player"), displayName: "Player", reason: "Playing")],
            battery: BatteryState(percentage: 10, isOnBatteryPower: true)))
        let enforcer = makeEnforcer(sensors)
        enforcer.tick()
        sensors.uptime = 120
        sensors.inputs.idleSeconds = 120
        enforcer.tick()
        #expect(enforcer.batteryPlan?.shouldWarn == true)
        #expect(enforcer.effectiveSleepRemainingSeconds == 15)
        #expect(enforcer.batteryWarningPlan == nil, "Do not display a misleading sixty-second countdown")
        enforcer.pause(for: nil)
        #expect(enforcer.batteryWarningPlan?.remainingSeconds == 60, "Battery protection still applies while paused")
    }

    @Test func inputRestartsCriticalWindowAndBackgroundWakeDoesNot() {
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 59, settings: nil, blockers: [],
            battery: BatteryState(percentage: 5, isOnBatteryPower: true), humanInputCount: 1))
        let enforcer = makeEnforcer(sensors)
        enforcer.tick()
        sensors.inputs.idleSeconds = 0
        sensors.inputs.humanInputCount = 2
        enforcer.tick()
        #expect(enforcer.batteryPlan?.remainingSeconds == 60)
        #expect(enforcer.batteryPlan?.shouldWarn == false)
        enforcer.prepareForSleep()
        sensors.uptime = 300
        enforcer.tick()
        #expect(sensors.sleepCalls == 0, "Do not actuate while asleep")
        enforcer.didWake()
        #expect(sensors.sleepCalls == 0, "Someone opening the lid gets time to touch a key")
        #expect(enforcer.batteryPlan?.remainingSeconds == 60)
        #expect(enforcer.batteryPlan?.shouldWarn == true)
        sensors.uptime = 360
        enforcer.tick()
        #expect(sensors.sleepCalls == 1, "A wake without input does not renew the allowance")
        #expect(enforcer.batteryPlan?.remainingSeconds == 0)
    }

    @Test func preferencesPersistAndApplyWithoutRelaunch() {
        let suite = "BatteryPreferencesTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BatteryPreferences(defaults: defaults)
        #expect(preferences.isEnabled)
        #expect(preferences.reservePercentage == 20)
        preferences.isEnabled = false
        preferences.setReservePercentage(25)
        let restored = BatteryPreferences(defaults: defaults)
        #expect(!restored.isEnabled)
        #expect(restored.reservePercentage == 25)
        restored.setReservePercentage(.nan)
        #expect(restored.reservePercentage == 25)
        restored.setReservePercentage(100)
        #expect(restored.reservePercentage == 30)

        let sensors = TestSensors(EnforcerReadings(idleSeconds: 0, settings: nil, blockers: [],
            battery: BatteryState(percentage: 35, isOnBatteryPower: true)))
        let enforcer = makeEnforcer(sensors)
        enforcer.tick()
        #expect(enforcer.batteryPlan == nil)
        enforcer.batteryPreferences.setReservePercentage(30)
        enforcer.batterySettingsChanged()
        #expect(enforcer.batteryPlan != nil)
        enforcer.batteryPreferences.isEnabled = false
        enforcer.batterySettingsChanged()
        #expect(enforcer.batteryPlan == nil)
    }
}
