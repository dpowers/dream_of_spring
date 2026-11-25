//
//  BlockerStatus.swift
//  Dream Of Spring
//

import Foundation

/// What a single sleep-preventing assertion is actually achieving, given the
/// app's policies. Global vetoes (pause, capture, meetings, a Never timer)
/// are reported by the menu's Status line instead.
nonisolated enum BlockerStatus: Equatable, Sendable {
    /// The app asks to stay awake but Dream Of Spring sleeps the Mac anyway.
    /// Without Dream Of Spring, this app would block sleep.
    case overridden
    /// A policy lets this app keep the Mac awake. `remainingSeconds` is `nil`
    /// when nothing limits it; otherwise the idle time left before forced sleep.
    case keepingAwake(remainingSeconds: TimeInterval?, reason: Reason)

    enum Reason: Equatable, Sendable {
        case alwaysAllowed
        case allowedUpTo
        case closedLid
        /// Standalone programs only take part in closed-lid protection; ordinary
        /// enforcement never forces sleep on their account.
        case notEnforced
    }

    var isKeepingAwake: Bool {
        if case .keepingAwake = self { return true }
        return false
    }

    /// - Parameters:
    ///   - deadline: idle seconds at which this blocker's policy stops exempting
    ///     it (`.infinity` for always-allow); `nil` when no deadline exists.
    ///   - hasPolicy: whether the user saved a whitelist policy for this app.
    ///   - closedLidProtected: this blocker is eligible and the lid lease is active.
    ///   - batteryRemainingSeconds: battery reserve allowance; it overrides every policy.
    static func evaluate(participatesInEnforcement: Bool, hasPolicy: Bool,
                         deadline: TimeInterval?, idleSeconds: TimeInterval,
                         closedLidProtected: Bool,
                         batteryRemainingSeconds: TimeInterval?) -> BlockerStatus {
        if batteryRemainingSeconds == 0 { return .overridden }
        let battery = batteryRemainingSeconds
        if closedLidProtected { return .keepingAwake(remainingSeconds: battery, reason: .closedLid) }
        guard participatesInEnforcement else {
            return .keepingAwake(remainingSeconds: battery, reason: .notEnforced)
        }
        guard hasPolicy, let deadline, idleSeconds < deadline else { return .overridden }
        if !deadline.isFinite { return .keepingAwake(remainingSeconds: battery, reason: .alwaysAllowed) }
        let remaining = deadline - idleSeconds
        return .keepingAwake(remainingSeconds: min(remaining, battery ?? .infinity), reason: .allowedUpTo)
    }
}
