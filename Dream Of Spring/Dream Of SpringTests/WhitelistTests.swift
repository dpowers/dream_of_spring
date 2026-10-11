import Testing
import Foundation
@testable import Dream_Of_Spring

@Suite("Whitelist")
@MainActor
struct WhitelistTests {
    /// Each test gets its own in-process suite so they don't see each other's
    /// state and don't write into the real app's defaults.
    private func freshDefaults(_ label: String = #function) -> UserDefaults {
        let name = "WhitelistTests.\(label).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func effectiveThresholdForUnknownIDReturnsConfiguredTimeout() {
        let defaults = freshDefaults()
        let wl = Whitelist(defaults: defaults)
        let t = wl.effectiveThreshold(for: .bundleID("com.example.unknown"), configuredTimeout: 600)
        #expect(t == 600)
    }

    @Test func effectiveThresholdForAlwaysAllowIsInfinity() {
        let defaults = freshDefaults()
        let wl = Whitelist(defaults: defaults)
        let id: AppIdentifier = .bundleID("com.example.vivaldi")
        wl.setPolicy(.alwaysAllow, for: id)
        #expect(wl.effectiveThreshold(for: id, configuredTimeout: 600) == .infinity)
    }

    @Test func effectiveThresholdForAllowUpToClampsToTimeout() {
        let defaults = freshDefaults()
        let wl = Whitelist(defaults: defaults)
        let id: AppIdentifier = .bundleID("com.example.vivaldi")
        wl.setPolicy(.allowUpTo(seconds: 30), for: id)   // smaller than the system timer
        #expect(wl.effectiveThreshold(for: id, configuredTimeout: 600) == 600)
    }

    @Test func effectiveThresholdForAllowUpToUsesAbsoluteValue() {
        let defaults = freshDefaults()
        let wl = Whitelist(defaults: defaults)
        let id: AppIdentifier = .bundleID("com.example.vivaldi")
        wl.setPolicy(.allowUpTo(seconds: 1800), for: id)
        #expect(wl.effectiveThreshold(for: id, configuredTimeout: 60) == 1800)
    }

    @Test func persistedPoliciesSurviveARelaunch() {
        let defaults = freshDefaults()
        let id1: AppIdentifier = .bundleID("com.example.app1")
        let id2: AppIdentifier = .processName("daemon-x")
        do {
            let wl = Whitelist(defaults: defaults)
            wl.setPolicy(.alwaysAllow, for: id1)
            wl.setPolicy(.allowUpTo(seconds: 1800), for: id2)
        }
        let reloaded = Whitelist(defaults: defaults)
        #expect(reloaded.policy(for: id1) == .alwaysAllow)
        #expect(reloaded.policy(for: id2) == .allowUpTo(seconds: 1800))
    }

    @Test func legacyWhitelistEntriesMigrateToAlwaysAllow() throws {
        let defaults = freshDefaults()
        let legacyIDs: [AppIdentifier] = [
            .bundleID("com.vivaldi.Vivaldi"),
            .processName("backgroundtool")
        ]
        // Seed the pre-policy `[AppIdentifier]` shape under the old defaults
        // key so the loader sees it as if upgraded from an earlier release.
        let legacyData = try JSONEncoder().encode(legacyIDs)
        defaults.set(legacyData, forKey: "whitelistedApps")

        let wl = Whitelist(defaults: defaults)

        for id in legacyIDs {
            #expect(wl.policy(for: id) == .alwaysAllow,
                    "expected legacy entry \(id) to migrate to .alwaysAllow")
        }
        #expect(defaults.data(forKey: "whitelistedApps") == nil,
                "legacy key should be removed after migration")

        let reloaded = Whitelist(defaults: defaults)
        for id in legacyIDs {
            #expect(reloaded.policy(for: id) == .alwaysAllow,
                    "migration should be persisted under the new key")
        }
    }

    @Test func removeDeletesEntry() {
        let defaults = freshDefaults()
        let wl = Whitelist(defaults: defaults)
        let id: AppIdentifier = .bundleID("com.example.app")
        wl.setPolicy(.alwaysAllow, for: id)
        #expect(wl.contains(id))
        wl.remove(id)
        #expect(!wl.contains(id))
        #expect(wl.policy(for: id) == nil)
    }

    @Test func combinedPolicyShowsTheStrongestParentOrHelperExemption() {
        let wl = Whitelist(defaults: freshDefaults())
        let parent: AppIdentifier = .bundleID("com.example.app")
        let helper: AppIdentifier = .bundleID("com.example.app.helper")
        #expect(wl.policy(for: [parent, helper]) == nil)
        wl.setPolicy(.allowUpTo(seconds: 900), for: parent)
        wl.setPolicy(.allowUpTo(seconds: 1800), for: helper)
        #expect(wl.policy(for: [parent, helper]) == .allowUpTo(seconds: 1800))
        wl.setPolicy(.alwaysAllow, for: helper)
        #expect(wl.policy(for: [parent, helper]) == .alwaysAllow)
    }

    @Test func editingParentPolicyReplacesLegacyHelperExemptions() {
        let defaults = freshDefaults()
        let wl = Whitelist(defaults: defaults)
        let parent: AppIdentifier = .bundleID("com.example.app")
        let helper: AppIdentifier = .bundleID("com.example.app.helper")
        wl.setPolicy(.alwaysAllow, for: helper)
        wl.setPolicy(.allowUpTo(seconds: 900), for: parent, replacing: [helper])
        #expect(wl.policy(for: [parent, helper]) == .allowUpTo(seconds: 900))
        #expect(!wl.contains(helper))
        wl.setPolicy(nil, for: parent, replacing: [helper])
        #expect(wl.policy(for: [parent, helper]) == nil)
        #expect(Whitelist(defaults: defaults).policies.isEmpty)
    }
}
