import Foundation

nonisolated struct EnforcerSnapshot: Equatable, Sendable {
    var idleSeconds: TimeInterval
    var configuredTimeoutSeconds: TimeInterval
    /// True when at least one blocker is active *given current idle time and
    /// each blocker's whitelist policy* — i.e. its effective exemption window
    /// has elapsed. Pre-computed by the enforcer so the decider stays pure.
    var hasActiveBlocker: Bool
    /// True when any process is capturing from a camera or microphone. A
    /// forced sleep would kill the live call/recording, and the processes
    /// holding the real keep-awake assertions for calls are daemons the
    /// whitelist can never match — so this vetoes enforcement outright.
    var isCaptureActive: Bool
    var secondsSinceLastSleepAttempt: TimeInterval
    var isPaused: Bool
    /// Shared system-wide deadline, including whitelist exemptions and grace.
    var enforcementDeadlineSeconds: TimeInterval? = nil
    var isMeetingProtected: Bool = false
}

nonisolated enum EnforcerAction: Equatable, Sendable {
    case doNothing
    case requestSleep
}

nonisolated enum Decider {
    /// Small buffer past the configured timeout — avoids racing the OS by a fraction.
    static let graceSeconds: TimeInterval = 15

    /// After a sleep request that didn't take, wait this long before trying again.
    static let cooldownSeconds: TimeInterval = 120

    static func decide(_ s: EnforcerSnapshot) -> EnforcerAction {
        if s.isPaused { return .doNothing }
        if s.configuredTimeoutSeconds == 0 { return .doNothing }
        if s.isCaptureActive || s.isMeetingProtected { return .doNothing }
        if !s.hasActiveBlocker { return .doNothing }
        if s.secondsSinceLastSleepAttempt < cooldownSeconds { return .doNothing }
        let deadline = s.enforcementDeadlineSeconds ?? (s.configuredTimeoutSeconds + graceSeconds)
        if !deadline.isFinite || s.idleSeconds < deadline { return .doNothing }
        return .requestSleep
    }
}
