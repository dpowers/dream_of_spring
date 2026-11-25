//
//  AssertionOwnerTests.swift
//  Dream Of SpringTests
//
import Foundation
import Testing
@testable import Dream_Of_Spring

struct AssertionOwnerTests {
    private let parent = AssertionOwner(bundleID: "com.example.Backup", displayName: "Backup")
    private let helper = AssertionOwner(bundleID: "com.example.Backup.Agent", displayName: "Backup Agent")

    @Test func unregisteredEmbeddedHelperResolvesToParentApp() {
        let owner = resolve(path: "/Applications/Backup.app/Contents/Resources/Agent.app/Contents/MacOS/Agent")
        #expect(owner?.bundleID == parent.bundleID)
        #expect(owner?.displayName == parent.displayName)
        #expect(owner?.alternateBundleIDs == [helper.bundleID])
    }

    @Test func registeredHelperUsesParentAndRetainsLegacyIdentifier() {
        let owner = resolve(path: "/Applications/Backup.app/Contents/Resources/Agent.app/Contents/MacOS/Agent", runningApp: helper)
        #expect(owner?.bundleID == parent.bundleID)
        #expect(owner?.alternateBundleIDs == [helper.bundleID])
    }

    @Test func xpcServiceAndBareHelperResolveToContainingApp() {
        for path in ["/Applications/Backup.app/Contents/XPCServices/Worker.xpc/Contents/MacOS/Worker",
                     "/Applications/Backup.app/Contents/MacOS/BackgroundWorker"] {
            #expect(resolve(path: path)?.bundleID == parent.bundleID)
        }
    }

    @Test func directAppsAndMissingExecutableKeepTheirIdentity() {
        #expect(resolve(path: "/Applications/Backup.app/Contents/MacOS/Backup", runningApp: parent) == parent)
        #expect(AssertionOwnerResolver.resolve(runningApp: parent, executableURL: nil, bundleAt: { _ in nil }) == parent)
    }

    @Test func unrelatedDaemonsAndInvalidAppDirectoriesRemainExcluded() {
        #expect(resolve(path: "/usr/libexec/powerd") == nil)
        #expect(resolve(path: "/tmp/NotABundle.app/bin/worker") == nil)
    }

    @Test @MainActor func unregisteredLiveHelperUsesExecutablePathAndBundleMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentURL = directory.appendingPathComponent("Backup.app")
        let helperURL = parentURL.appendingPathComponent("Contents/Resources/Agent.app")
        for (url, identity) in [(parentURL, parent), (helperURL, helper)] {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": identity.bundleID, "CFBundleName": identity.displayName,
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "Agent"
            ], format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let executable = helperURL.appendingPathComponent("Contents/MacOS/Agent")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: executable)
        // This pauses only the fixture process; it never requests system sleep.
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let owner = try #require(PowerInfo.assertionOwner(pid: process.processIdentifier))
        #expect(owner.bundleID == parent.bundleID)
        #expect(owner.displayName == parent.displayName)
        #expect(owner.alternateBundleIDs == [helper.bundleID])
    }

    @Test(arguments: ["com.example.Backup", "com.example.Backup.Agent"])
    @MainActor func parentAndLegacyHelperWhitelistProtectAgainstAnUnrelatedBlocker(allowedBundleID: String) throws {
        let owner = try #require(resolve(path: "/Applications/Backup.app/Contents/Resources/Agent.app/Contents/MacOS/Agent"))
        let defaults = UserDefaults(suiteName: "AssertionOwnerTests." + UUID().uuidString)!
        let whitelist = Whitelist(defaults: defaults)
        whitelist.setPolicy(.alwaysAllow, for: .bundleID(allowedBundleID))
        let sensors = TestSensors(EnforcerReadings(idleSeconds: 3600,
            settings: PowerSettings(timeoutSeconds: 600, source: "AC Power"),
            blockers: [Blocker(pid: 1, identifier: .bundleID(owner.bundleID), displayName: owner.displayName,
                               reason: "Backup", alternateIdentifiers: owner.alternateBundleIDs.map(AppIdentifier.bundleID)),
                       Blocker(pid: 2, identifier: .bundleID("com.example.Editor"), displayName: "Editor", reason: "Working")]))
        let enforcer = SleepEnforcer(whitelist: whitelist, startAutomatically: false, uptime: { sensors.uptime },
            readInputs: { sensors.inputs }, requestSleep: { sensors.sleepCalls += 1; return true })
        enforcer.tick()
        sensors.uptime = 120
        enforcer.tick()
        #expect(enforcer.sleepDeadlineSeconds == .infinity)
        #expect(sensors.sleepCalls == 0)
        #expect(!enforcer.activeBlockers.contains { $0.pid == 1 })
        #expect(!enforcer.nonAlwaysAllowedBlockers.contains { $0.pid == 1 })
        whitelist.remove(.bundleID(allowedBundleID))
        enforcer.tick()
        #expect(sensors.sleepCalls == 1)
    }

    private func resolve(path: String, runningApp: AssertionOwner? = nil) -> AssertionOwner? {
        AssertionOwnerResolver.resolve(runningApp: runningApp, executableURL: URL(filePath: path)) { url in
            switch url.path {
            case "/Applications/Backup.app": return parent
            case "/Applications/Backup.app/Contents/Resources/Agent.app": return helper
            default: return nil
            }
        }
    }

    @Test func daemonAssertionsHeldForAnotherProcessAreRecognised() {
        let forGame: [String: Any] = ["AssertType": "PreventUserIdleSystemSleep", "AssertionOnBehalfOfPID": NSNumber(value: 65930)]
        #expect(PowerInfo.isHeldOnBehalfOfAnotherProcess(forGame, ownerPID: 748))
        #expect(!PowerInfo.isHeldOnBehalfOfAnotherProcess(forGame, ownerPID: 65930))
        #expect(!PowerInfo.isHeldOnBehalfOfAnotherProcess(["AssertType": "PreventUserIdleSystemSleep"], ownerPID: 748))
    }
}
