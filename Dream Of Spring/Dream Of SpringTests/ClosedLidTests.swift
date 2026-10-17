//
//  ClosedLidTests.swift
//  Dream Of SpringTests
//
import Foundation
import Testing
@testable import Dream_Of_Spring

@MainActor
struct ClosedLidTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ClosedLidTests." + UUID().uuidString)!
    }

    private func inputs() -> EnforcerReadings {
        EnforcerReadings(idleSeconds: 1000, settings: PowerSettings(timeoutSeconds: 60, source: "AC Power"),
            blockers: [Blocker(pid: 123, identifier: .bundleID("backup"), displayName: "Backup", reason: "Backing up")],
            battery: BatteryState(percentage: 80, isOnBatteryPower: false), humanInputCount: 1, lidState: .open)
    }

    private func enforcer(_ sensors: TestSensors, controller: ClosedLidController? = nil) -> SleepEnforcer {
        let store = defaults()
        return SleepEnforcer(whitelist: Whitelist(defaults: store), batteryPreferences: BatteryPreferences(defaults: store),
            closedLidPreferences: ClosedLidPreferences(defaults: store), closedLidController: controller,
            startAutomatically: false, uptime: { sensors.uptime }, readInputs: { sensors.inputs },
            requestSleep: { sensors.sleepCalls += 1; return true })
    }

    @Test func permissionsPersistWithoutUpgradingExistingWhitelistEntries() {
        let store = defaults()
        let id = AppIdentifier.bundleID("backup")
        Whitelist(defaults: store).setPolicy(.alwaysAllow, for: id)
        let preferences = ClosedLidPreferences(defaults: store)
        #expect(preferences.permission(for: [id]) == nil)
        preferences.set(ClosedLidPermission(), for: id)
        #expect(ClosedLidPreferences(defaults: store).permission(for: [id])?.onlyOnExternalPower == true)
        preferences.set(ClosedLidPermission(onlyOnExternalPower: false), for: id)
        #expect(ClosedLidPreferences(defaults: store).permission(for: [id])?.onlyOnExternalPower == false)
        preferences.set(nil, for: id)
        #expect(ClosedLidPreferences(defaults: store).permissions.isEmpty)
        #expect(Whitelist(defaults: store).policy(for: id) == .alwaysAllow)
    }

    @Test func onlyPermittedActiveSystemAssertionsQualify() {
        let sensors = TestSensors(inputs())
        let app = enforcer(sensors)
        app.tick()
        #expect(app.closedLidLeaseSeconds == 0)
        app.closedLidPreferences.set(ClosedLidPermission(), for: .bundleID("backup"))
        app.tick()
        #expect(app.closedLidLeaseSeconds == 10)
        sensors.uptime = 120
        app.tick()
        #expect(sensors.sleepCalls == 0, "Permission also vetoes ordinary forced sleep while work is protected")
        for type in ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion", "PreventSystemSleep", "UserIsActive"] {
            sensors.inputs.blockers[0].assertionType = type
            app.tick()
            #expect(app.closedLidLeaseSeconds == 0)
        }
        sensors.inputs.blockers[0].assertionType = "NoIdleSleepAssertion"
        app.tick()
        #expect(app.closedLidLeaseSeconds == 10)
        sensors.inputs.blockers = []
        app.tick()
        #expect(app.closedLidLeaseSeconds == 0, "A saved permission alone never prevents sleep")
    }

    @Test func aliasesAndExecutablePathsHaveExplicitPermissions() {
        let sensors = TestSensors(inputs())
        sensors.inputs.blockers[0].alternateIdentifiers = [.bundleID("backup.helper")]
        let app = enforcer(sensors)
        app.closedLidPreferences.set(ClosedLidPermission(), for: .bundleID("backup.helper"))
        app.tick()
        #expect(app.closedLidLeaseSeconds == 10)
        sensors.inputs.blockers = [Blocker(pid: 456, identifier: .executablePath("/usr/local/bin/job"), displayName: "job", reason: "Working")]
        app.closedLidPreferences.set(ClosedLidPermission(), for: .executablePath("/opt/bin/job"))
        app.tick()
        #expect(app.closedLidLeaseSeconds == 0, "A same-name executable elsewhere does not inherit permission")
        app.closedLidPreferences.set(ClosedLidPermission(), for: .executablePath("/usr/local/bin/job"))
        app.tick()
        #expect(app.closedLidLeaseSeconds == 10)
    }

    @Test func powerAndMissingReadingsReleaseProtection() {
        let sensors = TestSensors(inputs())
        let app = enforcer(sensors)
        app.closedLidPreferences.set(ClosedLidPermission(), for: .bundleID("backup"))
        app.tick()
        #expect(app.closedLidLeaseSeconds == 10)
        sensors.inputs.battery = BatteryState(percentage: 80, isOnBatteryPower: true)
        app.tick()
        #expect(app.closedLidLeaseSeconds == 0)
        app.closedLidPreferences.set(ClosedLidPermission(onlyOnExternalPower: false), for: .bundleID("backup"))
        app.tick()
        #expect(app.closedLidLeaseSeconds == 10)
        sensors.inputs.assertionsAvailable = false
        app.tick()
        #expect(app.closedLidLeaseSeconds == 0)
        sensors.inputs.assertionsAvailable = true
        sensors.inputs.lidState = .unavailable
        app.tick()
        #expect(app.closedLidLeaseSeconds == 0)
        sensors.inputs.lidState = .closed
        sensors.inputs.battery = nil
        app.tick()
        #expect(app.closedLidLeaseSeconds == 0)
    }

    @Test func batteryDeadlineReleasesBeforeSleepEvenDuringCooldown() {
        var requests: [Double] = []
        let controller = ClosedLidController(disabled: false, transport: { seconds, _, _, _, reply in
            requests.append(seconds)
            reply(true, "")
        })
        let sensors = TestSensors(inputs())
        sensors.inputs.idleSeconds = 55
        sensors.inputs.battery = BatteryState(percentage: 5, isOnBatteryPower: true)
        let app = enforcer(sensors, controller: controller)
        app.closedLidPreferences.set(ClosedLidPermission(onlyOnExternalPower: false), for: .bundleID("backup"))
        app.pause(for: nil)
        app.tick()
        #expect(requests == [5])
        #expect(app.effectiveSleepRemainingSeconds == 5)
        sensors.uptime = 5
        app.tick()
        #expect(requests.last == 0)
        #expect(!controller.isActive)
        #expect(sensors.sleepCalls == 1)
        sensors.uptime = 6
        app.tick()
        #expect(app.closedLidLeaseSeconds == 0)
        #expect(!controller.isActive)
        #expect(sensors.sleepCalls == 1, "Actuator cooldown must never restore lid protection")
    }

    @Test func sleepWaitsForHelperReleaseAndDoesNotRearmOnBackgroundWake() {
        var replies: [ClosedLidController.Reply] = []
        var requests: [Double] = []
        let controller = ClosedLidController(disabled: false, transport: { seconds, _, _, _, reply in
            requests.append(seconds)
            replies.append(reply)
        })
        let sensors = TestSensors(inputs())
        let app = enforcer(sensors, controller: controller)
        app.closedLidPreferences.set(ClosedLidPermission(), for: .bundleID("backup"))
        app.tick()
        #expect(requests == [10])
        app.sleepNow()
        #expect(sensors.sleepCalls == 0)
        replies.removeFirst()(true, "")
        #expect(requests == [10, 0])
        #expect(sensors.sleepCalls == 0)
        replies.removeFirst()(true, "")
        #expect(sensors.sleepCalls == 1)
        app.prepareForSleep()
        app.didWake()
        #expect(app.closedLidLeaseSeconds == 0)
        sensors.inputs.humanInputCount = 2
        app.tick()
        #expect(app.closedLidLeaseSeconds == 10)
        replies.removeFirst()(true, "")
        controller.update(seconds: 0, protectBattery: true, reserve: 20)
        replies.removeFirst()(true, "")
    }

    @Test func failedRestorationDoesNotRaceSleepActuator() {
        let controller = ClosedLidController(disabled: false, transport: { seconds, _, _, _, reply in
            reply(seconds > 0, seconds == 0 ? "Restoration failed" : "")
        })
        let sensors = TestSensors(inputs())
        let app = enforcer(sensors, controller: controller)
        app.closedLidPreferences.set(ClosedLidPermission(), for: .bundleID("backup"))
        app.tick()
        app.sleepNow()
        #expect(sensors.sleepCalls == 0)
        #expect(app.lastActuatorFailed)
        #expect(app.closedLidSuspended)
    }

    @Test func inputDuringRestorationCancelsAutomaticSleep() {
        var replies: [ClosedLidController.Reply] = []
        let controller = ClosedLidController(disabled: false, transport: { _, _, _, _, reply in replies.append(reply) })
        let sensors = TestSensors(inputs())
        sensors.inputs.idleSeconds = 59
        sensors.inputs.battery = BatteryState(percentage: 5, isOnBatteryPower: true)
        let app = enforcer(sensors, controller: controller)
        app.closedLidPreferences.set(ClosedLidPermission(onlyOnExternalPower: false), for: .bundleID("backup"))
        app.tick()
        replies.removeFirst()(true, "")
        sensors.uptime = 1
        app.tick()
        #expect(sensors.sleepCalls == 0)
        sensors.inputs.humanInputCount = 2
        sensors.inputs.idleSeconds = 0
        app.tick()
        replies.removeFirst()(true, "")
        #expect(sensors.sleepCalls == 0)
    }

    @Test func additionalStandaloneRowsDoNotBroadenForcedSleep() {
        let sensors = TestSensors(inputs())
        sensors.inputs.blockers[0].participatesInEnforcement = false
        let app = enforcer(sensors)
        app.tick()
        sensors.uptime = 120
        app.tick()
        #expect(app.sleepDeadlineSeconds == nil)
        #expect(sensors.sleepCalls == 0)
    }
}

nonisolated private final class LeaseFixture {
    var disabled: Bool? = false
    var journaled = false
    var writes: [Bool] = []
    var failRestore = false
    var failJournal = false
    func makeLease(recovering: Bool = false) -> ClosedLidLease {
        ClosedLidLease(recovering: recovering, readDisabled: { self.disabled }, writeDisabled: {
            self.writes.append($0)
            if !$0 && self.failRestore { return false }
            self.disabled = $0
            return true
        }, journal: {
            if self.failJournal { return false }
            self.journaled = $0
            return true
        })
    }
}

struct ClosedLidLeaseTests {
    @Test func leaseExpiresWithoutClientAndRenewalsDoNotRewriteSettings() {
        let fixture = LeaseFixture()
        let lease = fixture.makeLease()
        #expect(lease.renew(seconds: 1000, now: 0, permitted: true))
        #expect(lease.expiresAt == 10)
        #expect(fixture.journaled)
        #expect(lease.renew(seconds: 10, now: 2, permitted: true))
        #expect(fixture.writes == [true])
        #expect(lease.expire(now: 11, permitted: true))
        #expect(fixture.disabled == true)
        #expect(lease.expire(now: 12, permitted: true))
        #expect(fixture.disabled == false)
        #expect(!fixture.journaled)
    }

    @Test func recoveryAndFailedRestorationRetainJournalUntilSuccess() {
        let fixture = LeaseFixture()
        fixture.disabled = true
        fixture.journaled = true
        fixture.failRestore = true
        let lease = fixture.makeLease(recovering: true)
        #expect(!lease.release())
        #expect(lease.ownsOverride)
        #expect(fixture.journaled)
        fixture.failRestore = false
        #expect(lease.expire(now: 1, permitted: false))
        #expect(fixture.disabled == false)
        #expect(!fixture.journaled)
    }

    @Test func anotherUtilityUnknownSettingsAndJournalFailureNeverEnableOverride() {
        for initial: Bool? in [true, nil] {
            let fixture = LeaseFixture()
            fixture.disabled = initial
            #expect(!fixture.makeLease().renew(seconds: 10, now: 0, permitted: true))
            #expect(fixture.writes.isEmpty)
        }
        let fixture = LeaseFixture()
        fixture.failJournal = true
        #expect(!fixture.makeLease().renew(seconds: 10, now: 0, permitted: true))
        #expect(fixture.writes.isEmpty)
    }

    @Test func batteryOrPowerVetoReleasesWithoutWaitingForExpiry() {
        let fixture = LeaseFixture()
        let lease = fixture.makeLease()
        #expect(lease.renew(seconds: 10, now: 0, permitted: true))
        #expect(lease.expire(now: 1, permitted: false))
        #expect(fixture.disabled == false)
        #expect(!lease.ownsOverride)
    }
}
