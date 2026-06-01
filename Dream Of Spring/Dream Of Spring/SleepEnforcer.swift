import Foundation
import Observation
import os

@MainActor
@Observable
final class SleepEnforcer {
    private static let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "enforcer")

    private(set) var idleSeconds: TimeInterval = 0
    private(set) var configuredTimeoutSeconds: TimeInterval = 0
    private(set) var powerSource: String = ""
    private(set) var blockers: [Blocker] = []
    private(set) var lastDecision: EnforcerAction = .doNothing
    private(set) var lastSleepAttemptAt: Date?
    /// `true` if the most recent actuator call failed. Cleared on success or
    /// when no attempt has been made yet. Surfaced in the menu so a stuck
    /// actuator isn't silently looping every cooldown interval.
    private(set) var lastActuatorFailed: Bool = false
    private(set) var isPaused: Bool = false
    private(set) var pausedUntil: Date?

    let whitelist: Whitelist
    private let requestSleep: @MainActor () -> Bool

    private static let pollInterval: Duration = .seconds(30)

    init(
        whitelist: Whitelist? = nil,
        requestSleep: @MainActor @escaping () -> Bool = {
            print("[Dream Of Spring] would call IOPMSleepSystem now")
            return true
        }
    ) {
        self.whitelist = whitelist ?? Whitelist()
        self.requestSleep = requestSleep
        tick()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SleepEnforcer.pollInterval)
                self?.tick()
            }
        }
    }

    /// Blockers whose whitelist policy doesn't (yet) exempt them given the
    /// current idle time. Drives both the decision logic and the menu's
    /// "Status" line.
    var activeBlockers: [Blocker] {
        blockers.filter { isActive(blocker: $0) }
    }

    /// Blockers without an `.alwaysAllow` entry — including any `.allowUpTo`
    /// blockers whose grace window hasn't elapsed yet. Used by the status
    /// icon, where "active right now" is too narrow.
    var nonAlwaysAllowedBlockers: [Blocker] {
        blockers.filter { whitelist.policy(for: $0.identifier) != .alwaysAllow }
    }

    private func isActive(blocker: Blocker) -> Bool {
        idleSeconds >= whitelist.effectiveThreshold(
            for: blocker.identifier,
            configuredTimeout: configuredTimeoutSeconds
        )
    }

    func pause(for duration: TimeInterval?) {
        isPaused = true
        pausedUntil = duration.map { Date().addingTimeInterval($0) }
        if let duration {
            Self.logger.info("Paused for \(Int(duration), privacy: .public) seconds")
        } else {
            Self.logger.info("Paused indefinitely")
        }
    }

    func resume() {
        isPaused = false
        pausedUntil = nil
        Self.logger.info("Resumed")
    }

    private func tick() {
        // Auto-resume if a timed pause has elapsed.
        if isPaused, let until = pausedUntil, Date() >= until {
            resume()
        }

        idleSeconds = PowerInfo.userIdleSeconds()
        if let t = PowerInfo.activeSystemSleepTimeoutSeconds() {
            configuredTimeoutSeconds = t
        }
        // pmset failure: keep the last known timeout rather than collapsing to
        // 0, which the decider would interpret as the user choosing "Never".
        powerSource = PowerInfo.activePowerSourceKey()
        blockers = PowerInfo.blockingAssertions()

        let active = activeBlockers
        let snapshot = EnforcerSnapshot(
            idleSeconds: idleSeconds,
            configuredTimeoutSeconds: configuredTimeoutSeconds,
            hasActiveBlocker: !active.isEmpty,
            secondsSinceLastSleepAttempt: secondsSinceLastSleepAttempt,
            isPaused: isPaused
        )
        lastDecision = Decider.decide(snapshot)
        if lastDecision == .requestSleep {
            Self.logger.info("Forcing sleep — idle=\(Int(self.idleSeconds), privacy: .public)s timeout=\(Int(self.configuredTimeoutSeconds), privacy: .public)s active-blockers=\(active.count, privacy: .public)")
            lastActuatorFailed = !requestSleep()
            lastSleepAttemptAt = Date()
        } else if active.isEmpty {
            // Nothing is keeping the Mac awake any more (user returned, or the
            // blocker released its assertion), so a prior failure is stale —
            // clear it rather than showing the warning until the next attempt.
            lastActuatorFailed = false
        }
    }

    private var secondsSinceLastSleepAttempt: TimeInterval {
        guard let last = lastSleepAttemptAt else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(last)
    }
}
