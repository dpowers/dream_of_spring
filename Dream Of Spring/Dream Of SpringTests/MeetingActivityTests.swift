//
//  MeetingActivityTests.swift
//  Dream Of SpringTests
//
import Foundation
import Testing
@testable import Dream_Of_Spring

struct MeetingActivityTests {
    @Test(arguments: ["us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "us.zoom.xos.helper"])
    func dedicatedMeetingAppProtectsWithoutCapture(bundleID: String) {
        #expect(MeetingActivity.state(runningBundleIDs: [bundleID], assertionReasons: []) == .active)
    }
    @Test(arguments: ["WebRTC has active PeerConnections", "Screen Sharing", "Active call", "AVConference"])
    func daemonAndBrowserReasonsProtectWithoutGUIApp(reason: String) {
        #expect(MeetingActivity.state(runningBundleIDs: [], assertionReasons: [reason]) == .active)
    }
    @Test func ordinaryPlaybackDoesNotCountAsMeeting() {
        #expect(MeetingActivity.state(runningBundleIDs: ["com.google.Chrome"], assertionReasons: ["Video Wake Lock"]) == .inactive)
        #expect(MeetingActivity.state(runningBundleIDs: [], assertionReasons: nil) == .unknown)
        #expect(MeetingActivity.state(runningBundleIDs: ["us.zoom.xos"], assertionReasons: nil) == .active)
    }
    @Test @MainActor func cameraOffMeetingVetoesUnrelatedBlockerUntilAfterMeetingEnds() {
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 3600,
            settings: PowerSettings(timeoutSeconds: 60, source: "AC Power"),
            blockers: [Blocker(pid: 1, identifier: .bundleID("browser"), displayName: "Browser", reason: "Playback")],
            meetingActivity: .active))
        let wl = Whitelist(defaults: UserDefaults(suiteName: "MeetingTests." + UUID().uuidString)!)
        let enforcer = SleepEnforcer(whitelist: wl, startAutomatically: false, uptime: { sensors.uptime },
            readInputs: { sensors.inputs }, requestSleep: { sensors.sleepCalls += 1; return true })
        enforcer.tick()
        sensors.uptime = 3600; enforcer.tick()
        #expect(sensors.sleepCalls == 0)
        sensors.inputs.meetingActivity = .unknown; sensors.uptime = 3630; enforcer.tick()
        #expect(sensors.sleepCalls == 0)
        sensors.inputs.meetingActivity = .inactive; sensors.uptime = 3660; enforcer.tick()
        sensors.uptime = 3779; enforcer.tick()
        #expect(sensors.sleepCalls == 0)
        sensors.uptime = 3780; enforcer.tick()
        #expect(sensors.sleepCalls == 1)
    }
}
