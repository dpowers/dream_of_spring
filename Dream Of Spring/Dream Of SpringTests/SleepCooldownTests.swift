//
//  SleepCooldownTests.swift
//  Dream Of SpringTests
//
import Foundation
import Testing
@testable import Dream_Of_Spring

@MainActor
struct SleepCooldownTests {
    private final class Clock {
        var uptime: TimeInterval = 0
        var date = Date(timeIntervalSince1970: 1_000_000)
        var attempts = 0
    }

    @Test(arguments: [-3600.0, 3600.0], [false, true])
    func wallClockChangesDoNotChangeRetryDeadline(clockChange: TimeInterval, succeeds: Bool) {
        let clock = Clock()
        let suite = "SleepCooldownTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let enforcer = SleepEnforcer(
            whitelist: Whitelist(defaults: defaults), startAutomatically: false,
            uptime: { clock.uptime }, wallClock: { clock.date },
            readInputs: {
                EnforcerReadings(idleSeconds: 900,
                    settings: PowerSettings(timeoutSeconds: 60, source: "AC Power"),
                    blockers: [Blocker(pid: 1, identifier: .bundleID("example"),
                                       displayName: "Example", reason: "Playback")])
            }, requestSleep: { clock.attempts += 1; return succeeds })

        enforcer.tick()
        clock.uptime = 120
        enforcer.tick()
        #expect(clock.attempts == 1)
        #expect(enforcer.lastSleepAttemptAt == clock.date)

        clock.date = clock.date.addingTimeInterval(clockChange)
        clock.uptime = 150
        enforcer.tick()
        #expect(clock.attempts == 1, "A clock jump must not bypass the cooldown")
        clock.uptime = 239
        enforcer.tick()
        #expect(clock.attempts == 1)
        clock.uptime = 240
        enforcer.tick()
        #expect(clock.attempts == 2, "Retry after 120 monotonic seconds, even if wall time moved back")
        #expect(enforcer.lastSleepAttemptAt == clock.date)
    }
}
