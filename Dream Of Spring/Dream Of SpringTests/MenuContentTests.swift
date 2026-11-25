//
//  MenuContentTests.swift
//  Dream Of SpringTests
//

import AppKit
import ServiceManagement
import Testing
@testable import Dream_Of_Spring

@MainActor
struct MenuContentTests {
    @MainActor private final class Fixture {
        let suite = "MenuContentTests." + UUID().uuidString
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 0,
            settings: PowerSettings(timeoutSeconds: 0, source: "AC Power"), blockers: []))
        let enforcer: SleepEnforcer
        let content: MenuContent

        init() {
            let defaults = UserDefaults(suiteName: suite)!
            let sensors = sensors
            enforcer = SleepEnforcer(whitelist: Whitelist(defaults: defaults),
                batteryPreferences: BatteryPreferences(defaults: defaults),
                closedLidPreferences: ClosedLidPreferences(defaults: defaults),
                startAutomatically: false, uptime: { sensors.uptime },
                readInputs: { sensors.inputs }, requestSleep: { sensors.sleepCalls += 1; return true })
            content = MenuContent(enforcer: enforcer,
                launchAtLogin: LaunchAtLogin(startAutomatically: false, readStatus: { .notRegistered }))
            enforcer.tick()
        }

        func open() { content.menuWillOpen(content.menu) }
        func cleanUp() { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    @Test func pollingPreservesOpenSubtreeAndReopeningRefreshesSnapshot() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.open()
        let menu = fixture.content.menu
        let battery = try #require(menu.item(withTitle: "Battery Protection")?.submenu)
        let reserve = try #require(battery.item(withTitle: "Reserve target")?.submenu)
        let choice = try #require(reserve.item(withTitle: "25%"))

        // Exercise repeated monitor updates, including structural changes to
        // the blocker list, while retaining the same open menu hierarchy.
        for second in 1...5 {
            fixture.sensors.uptime = Double(second)
            fixture.sensors.inputs.idleSeconds = Double(second)
            fixture.sensors.inputs.blockers = [Blocker(pid: 1, identifier: .bundleID("example"),
                displayName: "Example", reason: "Playback")]
            fixture.enforcer.tick()
        }
        fixture.enforcer.batteryPreferences.setReservePercentage(25)

        #expect(fixture.enforcer.idleSeconds == 5)
        #expect(menu.item(withTitle: "Battery Protection")?.submenu === battery)
        #expect(battery.item(withTitle: "Reserve target")?.submenu === reserve)
        #expect(reserve.item(withTitle: "25%") === choice)
        #expect(choice.state == .off)
        #expect(menu.item(withTitle: "Nothing is blocking sleep") != nil)

        fixture.open()
        #expect(menu.item(withTitle: "Nothing is blocking sleep") == nil)
        let refreshed = try #require(menu.item(withTitle: "Battery Protection")?.submenu)
        #expect(refreshed.item(withTitle: "Reserve target")?.submenu?.item(withTitle: "25%")?.state == .on)
        #expect(fixture.sensors.sleepCalls == 0)
    }

    @Test func reserveSelectionAndToggleUpdatePreferences() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.open()
        let battery = try #require(fixture.content.menu.item(withTitle: "Battery Protection")?.submenu)
        let reserve = try #require(battery.item(withTitle: "Reserve target")?.submenu)
        reserve.performActionForItem(at: reserve.indexOfItem(withTitle: "30%"))
        #expect(fixture.enforcer.batteryPreferences.reservePercentage == 30)

        battery.performActionForItem(at: battery.indexOfItem(withTitle: "Preserve battery when unattended"))
        #expect(!fixture.enforcer.batteryPreferences.isEnabled)
        fixture.open()
        let refreshed = try #require(fixture.content.menu.item(withTitle: "Battery Protection")?.submenu)
        #expect(refreshed.item(withTitle: "Reserve target")?.isEnabled == false)
        #expect(refreshed.item(withTitle: "Preserve battery when unattended")?.state == .off)
    }

    @Test func nestedPolicyActionsPreserveAliasHandling() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let app = AppIdentifier.bundleID("example.app")
        let helper = AppIdentifier.bundleID("example.helper")
        fixture.enforcer.whitelist.setPolicy(.alwaysAllow, for: helper)
        fixture.sensors.inputs.blockers = [Blocker(pid: 1, identifier: app,
            displayName: "Example", reason: "Playback", alternateIdentifiers: [helper])]
        fixture.enforcer.tick()
        fixture.open()
        let policies = try #require(fixture.content.menu.items.first { $0.title.contains("Example — Playback") }?.submenu)
        #expect(policies.item(withTitle: "Always allow")?.state == .on)
        policies.performActionForItem(at: policies.indexOfItem(withTitle: "Allow up to 15 minutes"))
        #expect(fixture.enforcer.whitelist.policy(for: app) == .allowUpTo(seconds: 900))
        #expect(fixture.enforcer.whitelist.policy(for: helper) == nil)

        policies.performActionForItem(at: policies.indexOfItem(withTitle: "Allow keeping awake with lid closed"))
        #expect(fixture.enforcer.closedLidPreferences.permission(for: [app])?.onlyOnExternalPower == true)
    }

    @Test func blockersAreGroupedByWhetherTheyKeepTheMacAwake() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.sensors.inputs.settings = PowerSettings(timeoutSeconds: 300, source: "AC Power")
        fixture.sensors.inputs.idleSeconds = 315
        fixture.enforcer.whitelist.setPolicy(.allowUpTo(seconds: 900), for: .bundleID("video"))
        fixture.sensors.inputs.blockers = [
            Blocker(pid: 1, identifier: .bundleID("video"), displayName: "Video", reason: "Playback"),
            Blocker(pid: 2, identifier: .bundleID("other"), displayName: "Other", reason: "Sync")
        ]
        fixture.enforcer.tick()
        fixture.open()
        let titles = fixture.content.menu.items.map(\.title)
        let awake = try #require(titles.firstIndex(of: "Keeping the Mac awake:"))
        let overridden = try #require(titles.firstIndex(of: "Would block sleep without Dream Of Spring:"))
        #expect(titles[awake + 1] == "Video — Playback · 10 min left")
        #expect(titles[overridden + 1] == "Other — Sync")
        #expect(fixture.sensors.sleepCalls == 0)
    }

    /// Regression: an exhausted battery allowance overrides allow-listed apps;
    /// the group header must say why, or the allow list looks broken.
    @Test func exhaustedBatteryAllowanceLabelsOverriddenApps() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.enforcer.whitelist.setPolicy(.alwaysAllow, for: .bundleID("backup"))
        fixture.sensors.inputs.blockers = [
            Blocker(pid: 1, identifier: .bundleID("backup"), displayName: "Backup", reason: "NoSleep")
        ]
        // Below a 20% reserve on battery: at most 10 minutes without input.
        fixture.sensors.inputs.battery = BatteryState(percentage: 16, isOnBatteryPower: true)
        // The tracker measures from its first sample (at uptime 0), so advance
        // the clock with no new input instead of only reporting idle time.
        fixture.sensors.uptime = 700
        fixture.sensors.inputs.humanIdleSeconds = 700
        fixture.sensors.inputs.idleSeconds = 700
        fixture.enforcer.tick()
        #expect(fixture.enforcer.batteryPlan?.remainingSeconds == 0)
        fixture.open()
        let titles = fixture.content.menu.items.map(\.title)
        let header = try #require(titles.firstIndex(of: "Overridden by the battery limit:"))
        #expect(titles[header + 1] == "Backup — NoSleep")
        #expect(!titles.contains("Would block sleep without Dream Of Spring:"))
    }
}
