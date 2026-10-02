//
//  ActivityState.swift
//  Dream Of Spring
//
import Foundation

nonisolated enum ActivityState: Equatable, Sendable {
    case active, inactive, unknown

    static func sample(status: Int32, value: UInt32, bytes: UInt32) -> Self {
        guard status == 0, bytes == MemoryLayout<UInt32>.size else { return .unknown }
        return value == 0 ? .inactive : .active
    }

    static func combined(_ states: [Self]) -> Self {
        if states.contains(.active) { return .active }
        if states.contains(.unknown) { return .unknown }
        return .inactive
    }
}

/// Require a continuous period of confirmed inactivity, including at startup.
/// A monotonic clock prevents wall-clock changes from shortening this window.
nonisolated struct ActivityClearance {
    static let quietSeconds: TimeInterval = 120
    private var inactiveSince: TimeInterval?

    mutating func permitsSleep(state: ActivityState, uptime: TimeInterval) -> Bool {
        guard state == .inactive else {
            inactiveSince = nil
            return false
        }
        if inactiveSince == nil || uptime < inactiveSince! { inactiveSince = uptime }
        return uptime - inactiveSince! >= Self.quietSeconds
    }
}
