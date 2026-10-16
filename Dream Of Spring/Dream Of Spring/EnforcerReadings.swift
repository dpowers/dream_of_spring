//
//  EnforcerReadings.swift
//  Dream Of Spring
//
import Foundation

struct EnforcerReadings {
    var idleSeconds: TimeInterval
    var settings: PowerSettings?
    var blockers: [Blocker]
    var cameraActivity: ActivityState = .inactive
    var microphoneActivity: ActivityState = .inactive
    var meetingActivity: ActivityState = .inactive
    var battery: BatteryState? = nil
    var humanInputCount: UInt64? = nil
    var humanIdleSeconds: TimeInterval? = nil

    static func read() -> Self {
        let settings = PowerInfo.activeSettings()
        let assertions = PowerInfo.assertionSnapshot()
        let meeting = MeetingActivity.read(assertionReasons: assertions?.reasons)
        let camera = CaptureActivity.cameraInUse()
        let microphone = CaptureActivity.microphoneInUse()
        let battery = PowerInfo.batteryState()
        let human = PowerInfo.humanActivity()
        // Read idle last so the pmset subprocess cannot leave an old HID sample.
        return Self(idleSeconds: PowerInfo.userIdleSeconds(), settings: settings,
                    blockers: assertions?.blockers ?? [], cameraActivity: camera,
                    microphoneActivity: microphone, meetingActivity: meeting, battery: battery,
                    humanInputCount: human.count, humanIdleSeconds: human.idle)
    }

    /// Countdown polling avoids invoking pmset and enumerating capture devices
    /// every second. Normal enforcement is only evaluated on full samples.
    func refreshingBatteryAndInput() -> Self {
        var result = self
        result.battery = PowerInfo.batteryState()
        let human = PowerInfo.humanActivity()
        result.humanInputCount = human.count
        result.humanIdleSeconds = human.idle
        result.idleSeconds = PowerInfo.userIdleSeconds()
        return result
    }
}

nonisolated struct PowerSettings: Equatable, Sendable {
    let timeoutSeconds: TimeInterval
    let source: String

    static func validated(timeout: TimeInterval?, sourceBefore: String?, sourceAfter: String?) -> Self? {
        guard let timeout, timeout.isFinite, timeout >= 0,
              let sourceBefore, sourceBefore == sourceAfter else { return nil }
        return Self(timeoutSeconds: timeout, source: sourceBefore)
    }
}

struct AssertionReadings {
    let blockers: [Blocker]
    let reasons: [String]
}
