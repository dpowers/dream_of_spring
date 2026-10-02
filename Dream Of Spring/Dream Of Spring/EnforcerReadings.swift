//
//  EnforcerReadings.swift
//  Dream Of Spring
//
import Foundation

struct EnforcerReadings {
    var idleSeconds: TimeInterval
    var settings: PowerSettings?
    var blockers: [Blocker]
    var cameraInUse: Bool = false
    var microphoneInUse: Bool = false

    static func read() -> Self {
        let settings = PowerInfo.activeSettings()
        let blockers = PowerInfo.blockingAssertions()
        let camera = CaptureActivity.cameraInUse()
        let microphone = CaptureActivity.microphoneInUse()
        // Read idle last so the pmset subprocess cannot leave an old HID sample.
        return Self(idleSeconds: PowerInfo.userIdleSeconds(), settings: settings,
                    blockers: blockers, cameraInUse: camera, microphoneInUse: microphone)
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
