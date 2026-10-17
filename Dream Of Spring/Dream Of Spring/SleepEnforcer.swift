import Foundation
import Observation
import os
import Darwin

@MainActor
@Observable
final class SleepEnforcer {
    private static let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "enforcer")

    private(set) var idleSeconds: TimeInterval = 0
    private(set) var configuredTimeoutSeconds: TimeInterval = 0
    private(set) var hasValidSettings = false
    private(set) var powerSource: String = ""
    private(set) var battery: BatteryState?
    private var batteryProtection = BatteryProtection()
    var batteryPlan: BatteryPlan? { batteryProtection.plan }
    var batteryIdleLimitSeconds: TimeInterval? { batteryPlan?.idleLimitSeconds }
    var batteryDrainPerHour: Double? { batteryProtection.drainPerHour }
    let batteryPreferences: BatteryPreferences
    let closedLidPreferences: ClosedLidPreferences
    let closedLidController: ClosedLidController
    private(set) var lidState: LidState = .unavailable
    private(set) var closedLidLeaseSeconds: TimeInterval = 0
    private(set) var closedLidSuspended = false
    private var suspendedInputCount: UInt64?
    private var sleepRequestPending = false
    private var isTerminating = false
    private(set) var blockers: [Blocker] = []
    /// True when any process is capturing from the camera / microphone —
    /// a live call or recording. Battery reserve protection can override this.
    private(set) var cameraActivity: ActivityState = .unknown
    private(set) var microphoneActivity: ActivityState = .unknown
    private(set) var isCaptureProtected = true
    var cameraInUse: Bool { cameraActivity == .active }
    var microphoneInUse: Bool { microphoneActivity == .active }
    private var captureClearance = ActivityClearance()
    private var meetingClearance = ActivityClearance()
    var captureQuietSecondsRemaining: TimeInterval { captureClearance.remainingSeconds }
    var meetingQuietSecondsRemaining: TimeInterval { meetingClearance.remainingSeconds }
    private(set) var lastCaptureResetReason = "App startup"
    private(set) var lastCaptureResetAt: Date?
    private(set) var lastSampleAt: Date?
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

    private let startAutomatically: Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var powerSourceObserver: PowerSourceObserver?
    @ObservationIgnored private var warningController: BatteryWarningController?
    private var latestInputs: EnforcerReadings?
    private var lastFullSampleUptime: TimeInterval = 0
    private var isSleeping = false

    init(
        whitelist: Whitelist? = nil,
        batteryPreferences: BatteryPreferences? = nil,
        closedLidPreferences: ClosedLidPreferences? = nil,
        closedLidController: ClosedLidController? = nil,
        startAutomatically: Bool = true,
        uptime: @MainActor @escaping () -> TimeInterval = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 },
        wallClock: @MainActor @escaping () -> Date = { Date() },
        readInputs: @MainActor @escaping () -> EnforcerReadings = { EnforcerReadings.read() },
        requestSleep: @MainActor @escaping () -> Bool = {
            print("[Dream Of Spring] would call IOPMSleepSystem now")
            return true
        }
    ) {
        self.whitelist = whitelist ?? Whitelist()
        self.batteryPreferences = batteryPreferences ?? BatteryPreferences()
        self.closedLidPreferences = closedLidPreferences ?? ClosedLidPreferences()
        self.closedLidController = closedLidController ?? ClosedLidController(disabled: !startAutomatically || EnforcementRuntime.isDisabled)
        self.requestSleep = requestSleep
        self.readInputs = readInputs
        self.uptime = uptime
        self.wallClock = wallClock
        self.startAutomatically = startAutomatically
        guard startAutomatically else { return }
        self.closedLidController.prepareSupport()
        warningController = BatteryWarningController()
        powerSourceObserver = PowerSourceObserver(onChange: { [weak self] in self?.tick() },
            onSleep: { [weak self] in self?.prepareForSleep() },
            onWake: { [weak self] in self?.didWake() })
        tick()
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
        whitelist.sleepDeadline(for: blockers.filter(\.participatesInEnforcement).flatMap(\.policyIdentifiers), configuredTimeout: configuredTimeoutSeconds)
    }

    var eligibleClosedLidBlockers: [Blocker] {
        blockers.filter { blocker in
            guard blocker.requestsSystemSleepPrevention,
                  let permission = closedLidPreferences.permission(for: blocker.policyIdentifiers),
                  let battery else { return false }
            return !permission.onlyOnExternalPower || !battery.isOnBatteryPower
        }
    }

    var closedLidStatus: String {
        if closedLidController.hasFailure { return closedLidController.message }
        if lidState == .unavailable { return "Closed-lid protection unavailable: no readable lid sensor" }
        if closedLidSuspended { return "Closed-lid protection suspended until your next input" }
        if battery == nil { return "Closed-lid protection unavailable: battery status unknown" }
        if closedLidController.isActive {
            let names = Set(eligibleClosedLidBlockers.map(\.displayName)).sorted().joined(separator: ", ")
            return "Keeping awake with lid closed: \(names)"
        }
        if closedLidLeaseSeconds > 0 { return closedLidController.message }
        return "Closed-lid protection waiting for an allowed system-sleep assertion"
    }

    var effectiveSleepRemainingSeconds: TimeInterval? {
        let batteryRemaining = batteryPlan?.remainingSeconds
        guard closedLidLeaseSeconds == 0, !isPaused, hasValidSettings, configuredTimeoutSeconds > 0,
              !isCaptureProtected, !isMeetingProtected,
              let normal = sleepDeadlineSeconds, normal.isFinite else { return batteryRemaining }
        return min(batteryRemaining ?? .infinity, max(0, normal - idleSeconds))
    }

    var batteryWarningPlan: BatteryPlan? {
        guard let plan = batteryPlan,
              effectiveSleepRemainingSeconds == plan.remainingSeconds else { return nil }
        // Don't promise a battery countdown when the ordinary sleep deadline
        // will act sooner. Those earlier settings still take precedence.
        return plan
    }

    private func isActive(blocker: Blocker) -> Bool {
        if batteryPlan?.remainingSeconds == 0 { return true }
        guard blocker.participatesInEnforcement else { return false }
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
        guard !isSleeping, !isTerminating else { return }
        let inputs = readInputs()
        lastFullSampleUptime = uptime()
        evaluate(inputs, fullSample: true)
    }

    func batterySettingsChanged() { tick() }

    func closedLidSettingsChanged() {
        tick()
    }

    func sleepNow() {
        suspendClosedLidProtection()
        performSleepRequest(manual: true)
    }

    func prepareForTermination(_ completion: @escaping @MainActor () -> Void) {
        isTerminating = true
        pollTask?.cancel()
        closedLidController.releaseForSleep { success, _ in
            if success { completion() }
            else {
                // Even if the helper cannot reply, its independent lease expires.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(ClosedLidService.maximumLeaseSeconds + 1))
                    completion()
                }
            }
        }
    }

    private func suspendClosedLidProtection() {
        closedLidSuspended = true
        suspendedInputCount = startAutomatically ? PowerSafetyReadings.humanActivity().count : latestInputs?.humanInputCount
        closedLidLeaseSeconds = 0
        closedLidController.update(seconds: 0, protectBattery: batteryPreferences.isEnabled,
            reserve: batteryPreferences.reservePercentage)
    }

    private func performSleepRequest(manual: Bool = false) {
        guard !sleepRequestPending else { return }
        sleepRequestPending = true
        let inputCount = startAutomatically ? PowerSafetyReadings.humanActivity().count : latestInputs?.humanInputCount
        closedLidController.releaseForSleep { [weak self] success, _ in
            guard let self else { return }
            self.sleepRequestPending = false
            guard success, !self.isTerminating else { self.lastActuatorFailed = true; return }
            let currentInput = self.startAutomatically ? PowerSafetyReadings.humanActivity().count : self.latestInputs?.humanInputCount
            // The helper round trip is asynchronous. Input or a changed policy
            // during it may have cancelled an automatic sleep deadline.
            if !manual && (currentInput != inputCount || self.lastDecision != .requestSleep) { return }
            self.lastActuatorFailed = !self.requestSleep()
            self.lastSleepAttemptAt = self.wallClock()
            self.lastSleepAttemptUptime = self.uptime()
        }
    }

    func prepareForSleep() {
        suspendClosedLidProtection()
        isSleeping = true
        pollTask?.cancel()
        warningController?.hide()
        batteryProtection.resetDrainEstimate()
    }

    func didWake() {
        isSleeping = false
        // Preserve the interaction timestamp and deadline across every wake.
        batteryProtection.resetDrainEstimate()
        tick()
    }

    private func evaluate(_ inputs: EnforcerReadings, fullSample: Bool) {
        // Auto-resume if a timed pause has elapsed.
        if isPaused, let until = pausedUntil, wallClock() >= until {
            resume()
        }

        latestInputs = inputs
        idleSeconds = inputs.idleSeconds
        hasValidSettings = inputs.settings != nil
        configuredTimeoutSeconds = inputs.settings?.timeoutSeconds ?? 0
        powerSource = inputs.settings?.source ?? ""
        battery = inputs.battery
        batteryProtection.update(battery: battery, idle: inputs.humanIdleSeconds ?? idleSeconds,
                                 inputCount: inputs.humanInputCount, now: uptime(),
                                 enabled: batteryPreferences.isEnabled, reserve: batteryPreferences.reservePercentage)
        blockers = inputs.blockers
        lidState = inputs.lidState
        if closedLidSuspended, let previous = suspendedInputCount,
           let current = inputs.humanInputCount, previous != current {
            closedLidSuspended = false
        }
        closedLidLeaseSeconds = ClosedLidPolicy.leaseSeconds(lid: lidState, battery: battery,
            remainingBatterySeconds: batteryPlan?.remainingSeconds,
            suspended: closedLidSuspended || sleepRequestPending || isTerminating,
            hasEligibleAssertion: inputs.assertionsAvailable && !eligibleClosedLidBlockers.isEmpty)
        closedLidController.update(seconds: closedLidLeaseSeconds,
            allowOnBattery: eligibleClosedLidBlockers.contains {
                closedLidPreferences.permission(for: $0.policyIdentifiers)?.onlyOnExternalPower == false
            },
            protectBattery: batteryPreferences.isEnabled, reserve: batteryPreferences.reservePercentage)
        cameraActivity = inputs.cameraActivity
        microphoneActivity = inputs.microphoneActivity
        lastSampleAt = wallClock()
        let captureState = ActivityState.combined([cameraActivity, microphoneActivity])
        if fullSample && captureState != .inactive {
            var reasons: [String] = []
            if cameraActivity != .inactive {
                reasons.append(cameraActivity == .active ? "Camera in use" : "Camera status read failed")
            }
            if microphoneActivity != .inactive {
                reasons.append(microphoneActivity == .active ? "Microphone in use" : "Microphone status read failed")
            }
            lastCaptureResetReason = reasons.joined(separator: "; ")
            lastCaptureResetAt = lastSampleAt
            Self.logger.notice("Capture quiet window reset: \(self.lastCaptureResetReason, privacy: .public)")
        }
        let sampleUptime = uptime()
        meetingActivity = inputs.meetingActivity
        isMeetingProtected = !meetingClearance.permitsSleep(state: meetingActivity, uptime: sampleUptime)
        isCaptureProtected = !captureClearance.permitsSleep(
            state: captureState, uptime: sampleUptime)

        let active = activeBlockers
        let snapshot = EnforcerSnapshot(
            idleSeconds: idleSeconds,
            configuredTimeoutSeconds: configuredTimeoutSeconds,
            hasActiveBlocker: fullSample && blockers.contains(where: \.participatesInEnforcement),
            isCaptureActive: isCaptureProtected,
            secondsSinceLastSleepAttempt: secondsSinceLastSleepAttempt,
            isPaused: isPaused,
            enforcementDeadlineSeconds: sleepDeadlineSeconds,
            isMeetingProtected: isMeetingProtected,
            batteryIdleSeconds: batteryPlan?.idleSeconds ?? 0,
            batteryIdleLimitSeconds: batteryIdleLimitSeconds,
            isClosedLidProtected: closedLidLeaseSeconds > 0
        )
        lastDecision = Decider.decide(snapshot)
        if lastDecision == .requestSleep {
            Self.logger.info("Forcing sleep — idle=\(Int(self.idleSeconds), privacy: .public)s timeout=\(Int(self.configuredTimeoutSeconds), privacy: .public)s active-blockers=\(active.count, privacy: .public)")
            performSleepRequest()
        } else if active.isEmpty && batteryPlan?.remainingSeconds != 0 {
            // Nothing is keeping the Mac awake any more (user returned, or the
            // blocker released its assertion), so a prior failure is stale —
            // clear it rather than showing the warning until the next attempt.
            lastActuatorFailed = false
        }
        warningController?.update(plan: batteryWarningPlan, battery: battery, reserve: batteryPreferences.reservePercentage)
        scheduleNextPoll()
    }

    /// Shorten the final poll to the battery deadline; don't add the normal
    /// 15-second grace or a full polling interval to either battery cap.
    var nextPollSeconds: TimeInterval {
        let base = closedLidPreferences.permissions.isEmpty ? 30.0 : ClosedLidService.pollSeconds
        guard let plan = batteryPlan else { return base }
        let remaining = plan.remainingSeconds
        if remaining > 60 { return min(base, remaining - 60) }
        if remaining > 0 { return min(1, remaining) }
        let cooldown = Decider.cooldownSeconds - secondsSinceLastSleepAttempt
        return cooldown > 0 ? min(base, cooldown) : base
    }

    private func scheduleNextPoll() {
        guard startAutomatically, !isSleeping, !isTerminating else { return }
        pollTask?.cancel()
        let delay = nextPollSeconds
        pollTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            if self.uptime() - self.lastFullSampleUptime >= 30 || self.latestInputs == nil {
                self.tick()
            } else if let inputs = self.latestInputs {
                self.evaluate(inputs.refreshingBatteryAndInput(refreshAssertions: !self.closedLidPreferences.permissions.isEmpty), fullSample: false)
            }
        }
    }

    private var secondsSinceLastSleepAttempt: TimeInterval {
        guard let last = lastSleepAttemptUptime else { return .greatestFiniteMagnitude }
        return uptime() - last
    }

    /// Uses cached samples so copying diagnostics cannot trigger enforcement.
    var diagnostics: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let deadline = sleepDeadlineSeconds.map { String($0) } ?? "none"
        let blockerLines = blockers.map { "\($0.displayName) (PID \($0.pid)): \($0.reason)" }.joined(separator: "\n")
        return """
        Dream Of Spring \(version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Last sample: \(lastSampleAt?.ISO8601Format() ?? "none")
        Paused: \(isPaused)
        Power settings valid: \(hasValidSettings); source: \(powerSource)
        Battery: \(battery.map { String($0.percentage) + "%; on battery: " + String($0.isOnBatteryPower) } ?? "unavailable"); idle cap: \(batteryIdleLimitSeconds.map { String($0) + "s" } ?? "none")
        Reserve protection: \(batteryPreferences.isEnabled); target: \(batteryPreferences.reservePercentage)%
        Drain: \(batteryDrainPerHour.map { String($0) + " percentage points/hour" } ?? "estimating"); reason: \(batteryPlan?.reason.rawValue ?? "none")
        Human idle: \(batteryPlan?.idleSeconds ?? 0)s; battery time remaining: \(batteryPlan?.remainingSeconds ?? 0)s
        Idle: \(idleSeconds)s; configured timeout: \(configuredTimeoutSeconds)s; enforcement deadline: \(deadline)s
        Camera: \(cameraActivity.rawValue); microphone: \(microphoneActivity.rawValue)
        Capture protected: \(isCaptureProtected); quiet time remaining: \(captureQuietSecondsRemaining)s
        Last capture wait reset: \(lastCaptureResetReason) at \(lastCaptureResetAt?.ISO8601Format() ?? "startup")
        Meeting: \(meetingActivity.rawValue); protected: \(isMeetingProtected); quiet time remaining: \(meetingQuietSecondsRemaining)s
        Lid: \(lidState.rawValue); permission count: \(closedLidPreferences.permissions.count); lease: \(closedLidLeaseSeconds)s
        Closed-lid: \(closedLidStatus); helper: \(closedLidController.message)
        Decision: \(lastDecision)
        Last sleep request: \(lastSleepAttemptAt?.ISO8601Format() ?? "none"); failed: \(lastActuatorFailed)
        Blockers:
        \(blockerLines.isEmpty ? "none" : blockerLines)
        """
    }
}
