import Testing
import Foundation
@testable import Dream_Of_Spring

@Suite("Decider")
struct DeciderTests {
    private func snapshot(
        idle: TimeInterval = 700,
        timeout: TimeInterval = 600,
        blockers: Int = 1,
        sinceLastAttempt: TimeInterval = 9_999,
        paused: Bool = false
    ) -> EnforcerSnapshot {
        EnforcerSnapshot(
            idleSeconds: idle,
            configuredTimeoutSeconds: timeout,
            nonWhitelistedBlockerCount: blockers,
            secondsSinceLastSleepAttempt: sinceLastAttempt,
            isPaused: paused
        )
    }

    @Test func pastTimeoutWithBlockersFires() {
        #expect(Decider.decide(snapshot()) == .requestSleep)
    }

    @Test func pausedDoesNothing() {
        #expect(Decider.decide(snapshot(paused: true)) == .doNothing)
    }

    @Test func neverSleepDoesNothing() {
        #expect(Decider.decide(snapshot(timeout: 0)) == .doNothing)
    }

    @Test func noBlockersDoesNothing() {
        #expect(Decider.decide(snapshot(blockers: 0)) == .doNothing)
    }

    /// All blockers being whitelisted reduces the count to zero before the
    /// snapshot is built, so the decider should be a no-op.
    @Test func allWhitelistedDoesNothing() {
        #expect(Decider.decide(snapshot(blockers: 0)) == .doNothing)
    }

    /// At least one non-whitelisted blocker remains → fire.
    @Test func mixedWhitelistFires() {
        #expect(Decider.decide(snapshot(blockers: 1)) == .requestSleep)
    }

    @Test func cooldownSuppresses() {
        #expect(Decider.decide(snapshot(sinceLastAttempt: 30)) == .doNothing)
    }

    @Test func graceWindowSuppresses() {
        #expect(Decider.decide(snapshot(idle: 605, timeout: 600)) == .doNothing)
    }

    @Test func pastGraceFires() {
        #expect(Decider.decide(snapshot(idle: 620, timeout: 600)) == .requestSleep)
    }

    @Test func idleZeroDoesNothing() {
        #expect(Decider.decide(snapshot(idle: 0, timeout: 600)) == .doNothing)
    }
}
