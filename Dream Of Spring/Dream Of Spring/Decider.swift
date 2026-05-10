import Foundation

nonisolated struct EnforcerSnapshot: Equatable, Sendable {
    var idleSeconds: TimeInterval
    var configuredTimeoutSeconds: TimeInterval
    /// True when at least one blocker is active *given current idle time and
    /// each blocker's whitelist policy* — i.e. its effective exemption window
    /// has elapsed. Pre-computed by the enforcer so the decider stays pure.
    var hasActiveBlocker: Bool
    var secondsSinceLastSleepAttempt: TimeInterval
    var isPaused: Bool
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
        if !s.hasActiveBlocker { return .doNothing }
        if s.secondsSinceLastSleepAttempt < cooldownSeconds { return .doNothing }
        if s.idleSeconds < s.configuredTimeoutSeconds + graceSeconds { return .doNothing }
        return .requestSleep
    }
}
