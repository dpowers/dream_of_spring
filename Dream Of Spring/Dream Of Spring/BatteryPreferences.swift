//
//  BatteryPreferences.swift
//  Dream Of Spring
//

import Foundation
import Observation

@MainActor @Observable
final class BatteryPreferences {
    private let defaults: UserDefaults
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "batteryProtectionEnabled") } }
    private(set) var reservePercentage: Double

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: "batteryProtectionEnabled") as? Bool ?? true
        let saved = defaults.double(forKey: "batteryReservePercentage")
        reservePercentage = saved.isFinite && (15...30).contains(saved) ? saved : 20
    }

    func setReservePercentage(_ value: Double) {
        guard value.isFinite else { return }
        reservePercentage = min(30, max(15, value))
        defaults.set(reservePercentage, forKey: "batteryReservePercentage")
    }
}
