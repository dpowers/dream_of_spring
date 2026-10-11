import Foundation
import Observation
import os

@MainActor
@Observable
final class SleepEnforcer {
    private static let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "enforcer")

    private(set) var idleSeconds: TimeInterval = 0
    private(set) var configuredTimeoutSeconds: TimeInterval = 0
    private(set) var hasValidSettings = false
    private(set) var powerSource: String = ""
    private(set) var blockers: [Blocker] = []
    /// True when any process is capturing from the camera / microphone —
    /// a live call or recording. Either one vetoes forced sleep globally.
    private(set) var cameraActivity: ActivityState = .unknown
    private(set) var microphoneActivity: ActivityState = .unknown
    private(set) var isCaptureProtected = true
    var cameraInUse: Bool { cameraActivity == .active }
    var microphoneInUse: Bool { microphoneActivity == .active }
    private var captureClearance = ActivityClearance()
    private var meetingClearance = ActivityClearance()
    private(set) var meetingActivity: ActivityState = .unknown
    private(set) var isMeetingProtected = true
    private let uptime: @MainActor () -> TimeInterval
    private let wallClock: @MainActor () -> Date
    private(set) var lastDecision: EnforcerAction = .doNothing
    private(set) var lastSleepAttemptAt: Date?
    private var lastSleepAttemptUptime: TimeInterval?
    /// `true` if the most recent actuator call failed. Cleared on success or
    /// when no attempt has been made yet. Surfaced in the menu so a stuck
    /// actuator isn't silently looping every cooldown interval.
    private(set) var lastActuatorFailed: Bool = false
    private(set) var isPaused: Bool = false
    private(set) var pausedUntil: Date?

    let whitelist: Whitelist
    private let readInputs: @MainActor () -> EnforcerReadings
    private let requestSleep: @MainActor () -> Bool

    private static let pollInterval: Duration = .seconds(30)

    init(
        whitelist: Whitelist? = nil,
        startAutomatically: Bool = true,
        uptime: @MainActor @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallClock: @MainActor @escaping () -> Date = { Date() },
        readInputs: @MainActor @escaping () -> EnforcerReadings = { EnforcerReadings.read() },
        requestSleep: @MainActor @escaping () -> Bool = {
            print("[Dream Of Spring] would call IOPMSleepSystem now")
            return true
        }
    ) {
        self.whitelist = whitelist ?? Whitelist()
        self.requestSleep = requestSleep
        self.readInputs = readInputs
        self.uptime = uptime
        self.wallClock = wallClock
        guard startAutomatically else { return }
        tick()
        Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: SleepEnforcer.pollInterval) } catch { return }
                guard let self else { return }
                self.tick()
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
        blockers.filter { blocker in
            !blocker.policyIdentifiers.contains { whitelist.policy(for: $0) == .alwaysAllow }
        }
    }

    var sleepDeadlineSeconds: TimeInterval? {
        whitelist.sleepDeadline(for: blockers.flatMap(\.policyIdentifiers), configuredTimeout: configuredTimeoutSeconds)
    }

    private func isActive(blocker: Blocker) -> Bool {
        guard let deadline = whitelist.sleepDeadline(
            for: blocker.policyIdentifiers, configuredTimeout: configuredTimeoutSeconds
        ) else { return false }
        return idleSeconds >= deadline
    }

    func pause(for duration: TimeInterval?) {
        isPaused = true
        pausedUntil = duration.map { wallClock().addingTimeInterval($0) }
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

    func tick() {
        // Auto-resume if a timed pause has elapsed.
        if isPaused, let until = pausedUntil, wallClock() >= until {
            resume()
        }

        let inputs = readInputs()
        idleSeconds = inputs.idleSeconds
        hasValidSettings = inputs.settings != nil
        configuredTimeoutSeconds = inputs.settings?.timeoutSeconds ?? 0
        powerSource = inputs.settings?.source ?? ""
        blockers = inputs.blockers
        cameraActivity = inputs.cameraActivity
        microphoneActivity = inputs.microphoneActivity
        let sampleUptime = uptime()
        meetingActivity = inputs.meetingActivity
        isMeetingProtected = !meetingClearance.permitsSleep(state: meetingActivity, uptime: sampleUptime)
        isCaptureProtected = !captureClearance.permitsSleep(
            state: .combined([cameraActivity, microphoneActivity]), uptime: sampleUptime)

        let active = activeBlockers
        let snapshot = EnforcerSnapshot(
            idleSeconds: idleSeconds,
            configuredTimeoutSeconds: configuredTimeoutSeconds,
            hasActiveBlocker: !blockers.isEmpty,
            isCaptureActive: isCaptureProtected,
            secondsSinceLastSleepAttempt: secondsSinceLastSleepAttempt,
            isPaused: isPaused,
            enforcementDeadlineSeconds: sleepDeadlineSeconds,
            isMeetingProtected: isMeetingProtected
        )
        lastDecision = Decider.decide(snapshot)
        if lastDecision == .requestSleep {
            Self.logger.info("Forcing sleep — idle=\(Int(self.idleSeconds), privacy: .public)s timeout=\(Int(self.configuredTimeoutSeconds), privacy: .public)s active-blockers=\(active.count, privacy: .public)")
            lastActuatorFailed = !requestSleep()
            lastSleepAttemptAt = wallClock()
            lastSleepAttemptUptime = uptime()
        } else if active.isEmpty {
            // Nothing is keeping the Mac awake any more (user returned, or the
            // blocker released its assertion), so a prior failure is stale —
            // clear it rather than showing the warning until the next attempt.
            lastActuatorFailed = false
        }
    }

    private var secondsSinceLastSleepAttempt: TimeInterval {
        guard let last = lastSleepAttemptUptime else { return .greatestFiniteMagnitude }
        return uptime() - last
    }
}
