//
//  SleepTimerTests.swift
//  Dream Of SpringTests
//
import AppKit
import Foundation
import ServiceManagement
import Testing
@testable import Dream_Of_Spring

struct SleepTimerSettingsTests {
    private let laptop = """
    Battery Power:
     Sleep On Power Button 1
     standby              1
     displaysleep         5
     sleep                15
     disksleep            10
    AC Power:
     Sleep On Power Button 1
     displaysleep         10
     sleep                0 (sleep prevented by powerd)
     disksleep            10
    UPS Power:
     sleep                3
    """

    @Test func parsesPerSourceSystemAndDisplayTimers() throws {
        let settings = try #require(SleepTimerSettings.parse(custom: laptop))
        #expect(settings.timers[.battery] == .init(systemMinutes: 15, displayMinutes: 5))
        #expect(settings.timers[.ac] == .init(systemMinutes: 0, displayMinutes: 10))
        #expect(settings.timers.count == 2, "UPS settings are not exposed")
    }

    @Test func desktopReportsOnlyACAndGarbageIsRejected() throws {
        let desktop = try #require(SleepTimerSettings.parse(custom: "AC Power:\n sleep 30\n"))
        #expect(desktop.timers[.battery] == nil)
        #expect(desktop.timers[.ac]?.systemMinutes == 30)
        #expect(SleepTimerSettings.parse(custom: "") == nil)
        #expect(SleepTimerSettings.parse(custom: "Battery Power:\n sleep abc\n") == nil)
        #expect(SleepTimerSettings.parse(custom: " sleep 5\n") == nil, "Values outside a section are ignored")
    }

    @Test func helperArgumentsAreFixedAndBounded() {
        #expect(SleepTimerSettings.pmsetArguments(minutes: 15, source: .battery) == ["-b", "sleep", "15"])
        #expect(SleepTimerSettings.pmsetArguments(minutes: 0, source: .ac) == ["-c", "sleep", "0"])
        #expect(SleepTimerSettings.pmsetArguments(minutes: -1, source: .ac) == nil)
        #expect(SleepTimerSettings.pmsetArguments(minutes: 24 * 60 + 1, source: .ac) == nil)
        #expect(SleepTimerSource(rawValue: 2) == nil)
    }

    @Test func labels() {
        #expect(SleepTimerSettings.label(minutes: 0) == "Never")
        #expect(SleepTimerSettings.label(minutes: 45) == "45 min")
        #expect(SleepTimerSettings.label(minutes: 60) == "1 hour")
        #expect(SleepTimerSettings.label(minutes: 90) == "1 hr 30 min")
        #expect(SleepTimerSettings.label(minutes: 180) == "3 hours")
    }
}

@MainActor
struct SleepTimerControllerTests {
    @Test func successfulChangeRefreshesAndRunsCompletion() {
        var stored = SleepTimerSettings(timers: [.battery: .init(systemMinutes: 15, displayMinutes: 5)])
        var requests: [(Int, SleepTimerSource)] = []
        let controller = SleepTimerController(disabled: true, readSettings: { stored }, transport: { minutes, source, reply in
            requests.append((minutes, source))
            stored.timers[source]?.systemMinutes = minutes
            reply(true, "")
        })
        controller.refresh()
        var completions = 0
        controller.set(minutes: 3, for: .battery) { completions += 1 }
        #expect(requests.count == 1 && requests[0].0 == 3 && requests[0].1 == .battery)
        #expect(controller.settings?.timers[.battery]?.systemMinutes == 3)
        #expect(controller.failure == nil)
        #expect(completions == 1)
    }

    @Test func failureIsReportedAndInvalidValuesNeverReachHelper() {
        var requests = 0
        let controller = SleepTimerController(disabled: true, readSettings: { nil }, transport: { _, _, reply in
            requests += 1
            reply(false, "macOS rejected the sleep timer change")
        })
        controller.set(minutes: -5, for: .ac)
        controller.set(minutes: 100_000, for: .ac)
        #expect(requests == 0)
        controller.set(minutes: 10, for: .ac)
        #expect(requests == 1)
        #expect(controller.failure == "macOS rejected the sleep timer change")
        #expect(!controller.isChanging)
    }

    @Test func disabledRuntimeNeverReadsOrWritesRealSettings() {
        let controller = SleepTimerController(disabled: true)
        controller.refresh()
        #expect(controller.settings == nil)
        controller.set(minutes: 10, for: .ac)
        #expect(controller.failure != nil)
    }

    @Test func menuChoiceChangesTimerAndReEvaluates() throws {
        let suite = "SleepTimerMenu." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        var stored = SleepTimerSettings(timers: [
            .battery: .init(systemMinutes: 7, displayMinutes: 5),
            .ac: .init(systemMinutes: 10, displayMinutes: 5)])
        let timers = SleepTimerController(disabled: true, readSettings: { stored }, transport: { minutes, source, reply in
            stored.timers[source]?.systemMinutes = minutes
            reply(true, "")
        })
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 0,
            settings: PowerSettings(timeoutSeconds: 600, source: "AC Power"), blockers: []))
        var reads = 0
        let enforcer = SleepEnforcer(whitelist: Whitelist(defaults: defaults),
            batteryPreferences: BatteryPreferences(defaults: defaults),
            closedLidPreferences: ClosedLidPreferences(defaults: defaults),
            sleepTimers: timers, startAutomatically: false, uptime: { sensors.uptime },
            readInputs: { reads += 1; return sensors.inputs }, requestSleep: { sensors.sleepCalls += 1; return true })
        let content = MenuContent(enforcer: enforcer,
            launchAtLogin: LaunchAtLogin(startAutomatically: false, readStatus: { .notRegistered }))
        content.menuWillOpen(content.menu)
        let submenu = try #require(content.menu.item(withTitle: "Sleep Timers")?.submenu)
        let battery = try #require(submenu.item(withTitle: "On battery: 7 min")?.submenu)
        #expect(battery.item(withTitle: "7 min")?.state == .on, "Custom values stay visible")
        #expect(submenu.item(withTitle: "On power adapter: 10 min") != nil)
        #expect(submenu.item(withTitle: "Display turns off after: 5 min on battery, 5 min on power adapter") != nil)

        battery.performActionForItem(at: battery.indexOfItem(withTitle: "1 hour"))
        #expect(stored.timers[.battery]?.systemMinutes == 60)
        #expect(reads == 1, "A successful change triggers a fresh enforcement sample")
        #expect(sensors.sleepCalls == 0)

        content.menuWillOpen(content.menu)
        let refreshed = try #require(content.menu.item(withTitle: "Sleep Timers")?.submenu)
        #expect(refreshed.item(withTitle: "On battery: 1 hour")?.submenu?.item(withTitle: "1 hour")?.state == .on)
    }
}
