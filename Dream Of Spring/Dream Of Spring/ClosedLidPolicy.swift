//
//  ClosedLidPolicy.swift
//  Dream Of Spring
//
import Foundation
import Observation

nonisolated enum LidState: String, Sendable {
    case open, closed, unavailable
}

nonisolated struct ClosedLidPermission: Codable, Equatable, Sendable {
    var onlyOnExternalPower = true
}

nonisolated struct ClosedLidEntry: Codable {
    let id: AppIdentifier
    let permission: ClosedLidPermission
}

@MainActor @Observable
final class ClosedLidPreferences {
    private(set) var permissions: [AppIdentifier: ClosedLidPermission] = [:]
    private let defaults: UserDefaults
    private static let key = "closedLidPermissions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let entries = try? JSONDecoder().decode([ClosedLidEntry].self, from: data) {
            for entry in entries { permissions[entry.id] = entry.permission }
        }
    }

    func permission(for identifiers: [AppIdentifier]) -> ClosedLidPermission? {
        let matches = identifiers.compactMap { permissions[$0] }
        guard !matches.isEmpty else { return nil }
        return ClosedLidPermission(onlyOnExternalPower: matches.allSatisfy(\.onlyOnExternalPower))
    }

    func set(_ permission: ClosedLidPermission?, for id: AppIdentifier, replacing aliases: [AppIdentifier] = []) {
        for alias in aliases { permissions.removeValue(forKey: alias) }
        permissions[id] = permission
        let entries = permissions.map { ClosedLidEntry(id: $0.key, permission: $0.value) }
            .sorted { $0.id.sortKey < $1.id.sortKey }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}

nonisolated enum ClosedLidPolicy {
    /// Only an explicit system-sleep assertion expresses intent to do background work.
    /// Display assertions and coordinating assertions belonging to powerd do not qualify.
    static func isSystemAssertion(_ type: String) -> Bool {
        type == "PreventUserIdleSystemSleep" || type == "NoIdleSleepAssertion"
    }

    static func leaseSeconds(lid: LidState, battery: BatteryState?, remainingBatterySeconds: TimeInterval?,
                             suspended: Bool, hasEligibleAssertion: Bool) -> TimeInterval {
        guard lid != .unavailable, battery != nil, !suspended, hasEligibleAssertion else { return 0 }
        return max(0, min(ClosedLidService.maximumLeaseSeconds, remainingBatterySeconds ?? .infinity))
    }
}
