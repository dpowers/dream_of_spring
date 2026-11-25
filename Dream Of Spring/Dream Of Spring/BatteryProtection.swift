//
//  BatteryProtection.swift
//  Dream Of Spring
//

import Foundation

/// Only hardware input advances the last-interaction timestamp after startup.
/// A wake-induced reset of HIDIdleTime alone cannot renew an unattended budget.
nonisolated struct HumanActivityTracker {
    private var previousCount: UInt64?
    private var lastInputAt: TimeInterval?
    private var lastSampleAt: TimeInterval?

    mutating func sample(idle: TimeInterval, inputCount: UInt64?, now: TimeInterval) -> (idle: TimeInterval, interacted: Bool) {
        let validIdle = idle.isFinite && idle >= 0 ? idle : 0
        let firstSample = lastInputAt == nil || now < (lastSampleAt ?? now)
        let changed = inputCount != nil && previousCount != nil && inputCount != previousCount
        // Without a counter (e.g. injected sensors), detect a new last-input
        // timestamp, not just a smaller idle value between widely spaced polls.
        let fallbackInput = inputCount == nil && now - validIdle > (lastInputAt ?? now) + 1
        let interacted = changed || fallbackInput
        if firstSample || interacted { lastInputAt = now - validIdle }
        previousCount = inputCount
        lastSampleAt = now
        return (max(0, now - (lastInputAt ?? now)), interacted)
    }
}

/// Rolling estimates use percentage points, not remaining battery health.
/// Gaps, charging and upward recalibration invalidate the estimate.
nonisolated struct BatteryDrainEstimator {
    private struct Sample { let time: TimeInterval; let charge: Double }
    private var samples: [Sample] = []
    private(set) var percentagePointsPerHour: Double?
    private static let fullWindowSeconds: TimeInterval = 540

    mutating func reset() { samples = []; percentagePointsPerHour = nil }

    mutating func sample(_ battery: BatteryState?, now: TimeInterval) {
        guard let battery, battery.isOnBatteryPower, battery.percentage.isFinite,
              (0...100).contains(battery.percentage) else { reset(); return }
        if let last = samples.last {
            if now < last.time || now - last.time > 90 || battery.percentage > last.charge + 0.5 {
                reset()
            } else if now - last.time < 15 { return }
        }
        samples.append(Sample(time: now, charge: battery.percentage))
        samples.removeAll { now - $0.time > 600 }
        // Charge is reported in whole points, so a one-point step says only
        // that a boundary was crossed, not how long that point took. Trust a
        // single point across (nearly) the whole rolling window; any shorter
        // span of at least three minutes needs two.
        let rates = [samples.first, samples.last(where: { now - $0.time >= 180 })].compactMap { start -> Double? in
            guard let start, now - start.time >= 180 else { return nil }
            let drop = start.charge - battery.percentage
            guard drop >= (now - start.time >= Self.fullWindowSeconds ? 1 : 2) else { return nil }
            return drop / (now - start.time) * 3600
        }
        percentagePointsPerHour = rates.max()
    }
}

nonisolated struct BatteryPlan: Equatable, Sendable {
    enum Reason: String, Sendable { case reserve, lowBattery, criticalBattery, approachingReserve }
    let idleSeconds: TimeInterval
    let idleLimitSeconds: TimeInterval
    let reason: Reason
    var remainingSeconds: TimeInterval { max(0, idleLimitSeconds - idleSeconds) }
    var shouldWarn: Bool { idleSeconds >= 5 && remainingSeconds > 0 && remainingSeconds <= 60 }
}

nonisolated struct BatteryProtection {
    private var activity = HumanActivityTracker()
    private var estimator = BatteryDrainEstimator()
    private var deadline: TimeInterval?
    private var deadlineReason: BatteryPlan.Reason = .reserve
    private var previousReserve: Double?
    private var wakeFloor: TimeInterval?
    private(set) var plan: BatteryPlan?
    var drainPerHour: Double? { estimator.percentagePointsPerHour }

    mutating func resetDrainEstimate() { estimator.reset() }

    /// Seconds a person gets to touch a key after a full wake.
    static let wakeGraceSeconds: TimeInterval = 60

    /// A full wake does not renew the allowance, but an allowance that ran
    /// out while asleep must not put the Mac back to sleep before a person
    /// opening the lid can touch a key. Floor the deadline instead.
    mutating func noteWake(now: TimeInterval) { wakeFloor = now + Self.wakeGraceSeconds }

    mutating func update(battery: BatteryState?, idle: TimeInterval, inputCount: UInt64?,
                         now: TimeInterval, enabled: Bool, reserve: Double) {
        let attention = activity.sample(idle: idle, inputCount: inputCount, now: now)
        estimator.sample(battery, now: now)
        if attention.interacted || previousReserve != reserve { deadline = nil }
        previousReserve = reserve
        guard enabled, let battery, let cap = battery.idleLimitSeconds(reserve: reserve) else {
            deadline = nil
            plan = nil
            return
        }
        let lastInput = now - attention.idle
        var candidate = lastInput + cap
        var reason: BatteryPlan.Reason = battery.percentage <= 5 ? .criticalBattery
            : battery.percentage <= 10 ? .lowBattery : .reserve
        if battery.percentage > reserve, let rate = estimator.percentagePointsPerHour, rate > 0 {
            let timeToReserve = (battery.percentage - reserve) / rate * 3600
            // Preserve a minimum ten-minute utility window in the adaptive
            // band. The reserve is a target, while the low-charge caps are firm.
            let adaptive = max(lastInput + 600, now + timeToReserve)
            if adaptive < candidate { candidate = adaptive; reason = .approachingReserve }
        }
        // Estimates may tighten an existing deadline, but never repeatedly
        // push it back during the same period without human interaction.
        if deadline == nil || candidate < deadline! {
            deadline = candidate
            deadlineReason = reason
        }
        if let floor = wakeFloor, floor <= now { wakeFloor = nil }
        plan = BatteryPlan(idleSeconds: attention.idle,
                           idleLimitSeconds: max(0, max(deadline!, wakeFloor ?? deadline!) - lastInput),
                           reason: deadlineReason)
    }
}
