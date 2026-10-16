//
//  BatteryState.swift
//  Dream Of Spring
//

import Foundation

nonisolated struct BatteryState: Equatable, Sendable {
    let percentage: Double
    let isOnBatteryPower: Bool

    static func validated(currentCapacity: Double, maxCapacity: Double,
                          isOnBatteryPower: Bool) -> Self? {
        guard currentCapacity.isFinite, maxCapacity.isFinite,
              maxCapacity > 0, currentCapacity >= 0, currentCapacity <= maxCapacity else { return nil }
        return Self(percentage: currentCapacity / maxCapacity * 100,
                    isOnBatteryPower: isOnBatteryPower)
    }

    /// Fixed fallback limits; adaptive estimates can only shorten these.
    func idleLimitSeconds(reserve: Double = 20) -> TimeInterval? {
        guard isOnBatteryPower, percentage.isFinite, (0...100).contains(percentage) else { return nil }
        if percentage <= 5 { return 60 }
        if percentage <= 10 { return 3 * 60 }
        if percentage <= reserve { return 10 * 60 }
        if percentage <= reserve + 10 { return 30 * 60 }
        return nil
    }
}
