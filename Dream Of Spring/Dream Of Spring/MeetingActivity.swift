//
//  MeetingActivity.swift
//  Dream Of Spring
//
import AppKit

/// Capture is not a reliable meeting signal (phone audio, camera-off calls).
/// Protect dedicated meeting apps for their entire lifetime. Browser meetings
/// are protected by their WebRTC/screen-sharing assertions, including helpers
/// and daemons that are intentionally absent from the user-facing blocker list.
nonisolated enum MeetingActivity {
    static let protectedBundleIDs: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
        "com.apple.facetime", "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager", "com.cisco.webex"
    ]

    @MainActor static func read(assertionReasons: [String]?) -> ActivityState {
        state(runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
              assertionReasons: assertionReasons)
    }

    static func state(runningBundleIDs: Set<String>, assertionReasons: [String]?) -> ActivityState {
        if runningBundleIDs.contains(where: { id in
            let id = id.lowercased()
            return protectedBundleIDs.contains { id == $0 || id.hasPrefix($0 + ".") }
        }) { return .active }
        guard let assertionReasons else { return .unknown }
        let indicators = ["webrtc", "peerconnection", "screen sharing", "screensharing",
                          "screen capture", "screencapture", "video conferenc", "videoconferenc",
                          "avconferenc", "voip", "active call", "in a call", "voice chat", "zoom meeting"]
        return assertionReasons.contains { reason in
            indicators.contains { reason.lowercased().contains($0) }
        } ? .active : .inactive
    }
}
