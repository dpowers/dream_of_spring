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
    private(set) var isPaused: Bool = false
    private(set) var pausedUntil: Date?

    let whitelist: Whitelist
    private let requestSleep: @MainActor () -> Void

    private static let pollInterval: Duration = .seconds(30)

    init(
        whitelist: Whitelist? = nil,
        requestSleep: @MainActor @escaping () -> Void = {
            print("[Dream Of Spring] would call IOPMSleepSystem now")
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

    var nonWhitelistedBlockers: [Blocker] {
        blockers.filter { !whitelist.contains($0.identifier) }
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
        configuredTimeoutSeconds = PowerInfo.activeSystemSleepTimeoutSeconds()
        powerSource = PowerInfo.activePowerSourceKey()
        blockers = PowerInfo.blockingAssertions()

        let snapshot = EnforcerSnapshot(
            idleSeconds: idleSeconds,
            configuredTimeoutSeconds: configuredTimeoutSeconds,
            nonWhitelistedBlockerCount: nonWhitelistedBlockers.count,
            secondsSinceLastSleepAttempt: secondsSinceLastSleepAttempt,
            isPaused: isPaused
        )
        lastDecision = Decider.decide(snapshot)
        if lastDecision == .requestSleep {
            Self.logger.info("Forcing sleep — idle=\(Int(self.idleSeconds), privacy: .public)s timeout=\(Int(self.configuredTimeoutSeconds), privacy: .public)s blockers=\(snapshot.nonWhitelistedBlockerCount, privacy: .public)")
            requestSleep()
            lastSleepAttemptAt = Date()
        }
    }

    private var secondsSinceLastSleepAttempt: TimeInterval {
        guard let last = lastSleepAttemptAt else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(last)
    }
}
