//
//  MeetingActivity.swift
//  Dream Of Spring
//
import Foundation

/// Capture is not a reliable meeting signal (phone audio, camera-off calls),
/// so a call is also recognised by the name of any active power assertion,
/// including those of browser helpers and conferencing daemons that are
/// intentionally absent from the user-facing blocker list.
///
/// A meeting app that is merely running is not a meeting: Zoom and Teams
/// idle in the background for days. To protect an app's own calls beyond
/// these signals, give it an always-allow policy, which applies only while
/// it holds an assertion.
nonisolated enum MeetingActivity {
    static func state(assertionReasons: [String]?) -> ActivityState {
        guard let assertionReasons else { return .unknown }
        let indicators = ["webrtc", "peerconnection", "screen sharing", "screensharing",
                          "screen capture", "screencapture", "video conferenc", "videoconferenc",
                          "avconferenc", "voip", "active call", "in a call", "voice chat", "zoom meeting"]
        return assertionReasons.contains { reason in
            indicators.contains { reason.lowercased().contains($0) }
        } ? .active : .inactive
    }
}
