import Testing
import Foundation
@testable import Dream_Of_Spring

@Suite("Decider")
struct DeciderTests {
    private func snapshot(
        idle: TimeInterval = 700,
        timeout: TimeInterval = 600,
        hasActiveBlocker: Bool = true,
        captureActive: Bool = false,
        sinceLastAttempt: TimeInterval = 9_999,
        paused: Bool = false
    ) -> EnforcerSnapshot {
        EnforcerSnapshot(
            idleSeconds: idle,
            configuredTimeoutSeconds: timeout,
            hasActiveBlocker: hasActiveBlocker,
            isCaptureActive: captureActive,
            secondsSinceLastSleepAttempt: sinceLastAttempt,
            isPaused: paused
        )
    }

    @Test func pastTimeoutWithActiveBlockerFires() {
        #expect(Decider.decide(snapshot()) == .requestSleep)
    }

    @Test func pausedDoesNothing() {
        #expect(Decider.decide(snapshot(paused: true)) == .doNothing)
    }

    @Test func neverSleepDoesNothing() {
        #expect(Decider.decide(snapshot(timeout: 0)) == .doNothing)
    }

    /// No active blocker covers both "nothing is blocking" and "all blockers
    /// are exempt under their whitelist policies". The enforcer collapses
    /// both cases to the same snapshot field.
    @Test func noActiveBlockerDoesNothing() {
        #expect(Decider.decide(snapshot(hasActiveBlocker: false)) == .doNothing)
    }

    /// A live camera or microphone anywhere on the system vetoes enforcement
    /// even with a non-exempt blocker active past the grace window — forcing
    /// sleep would kill the call, and call apps' real keep-awake assertions
    /// are daemon-held, so no whitelist entry could protect them.
    @Test func captureActiveVetoes() {
        #expect(Decider.decide(snapshot(captureActive: true)) == .doNothing)
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

@Suite("WhitelistPolicy.effectiveThreshold")
struct WhitelistPolicyTests {
    @Test func alwaysAllowIsInfinity() {
        #expect(WhitelistPolicy.alwaysAllow.effectiveThreshold(configuredTimeout: 60) == .infinity)
    }

    @Test func allowUpToReturnsItsAbsoluteValueWhenLargerThanTimeout() {
        let t = WhitelistPolicy.allowUpTo(seconds: 1800).effectiveThreshold(configuredTimeout: 60)
        #expect(t == 1800)
    }

    /// If the user picks an extension shorter than the system timer, we clamp
    /// up — there's no sensible reading where the per-app threshold should
    /// fire earlier than the OS would have on its own.
    @Test func allowUpToClampsToTimeout() {
        let t = WhitelistPolicy.allowUpTo(seconds: 30).effectiveThreshold(configuredTimeout: 600)
        #expect(t == 600)
    }
}
