import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import AppKit
import Darwin
import os

nonisolated enum AppIdentifier: Hashable, Codable, Sendable {
    case bundleID(String)
    case processName(String)
}

extension AppIdentifier {
    /// Best-effort display name. For a `.bundleID`, prefers a running-app's
    /// localized name, falls back to a Launch Services bundle lookup, then
    /// finally the bundle ID itself.
    @MainActor
    var displayName: String {
        switch self {
        case .processName(let name):
            return name
        case .bundleID(let bid):
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bid {
                if let n = app.localizedName { return n }
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
               let bundle = Bundle(url: url) {
                let candidates: [String?] = [
                    bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
                    bundle.infoDictionary?["CFBundleDisplayName"] as? String,
                    bundle.localizedInfoDictionary?["CFBundleName"] as? String,
                    bundle.infoDictionary?["CFBundleName"] as? String
                ]
                if let n = candidates.compactMap({ $0 }).first { return n }
            }
            return bid
        }
    }
}

struct Blocker: Identifiable, Hashable, Sendable {
    let id = UUID()
    let pid: pid_t
    let identifier: AppIdentifier
    let displayName: String
    let reason: String
    var alternateIdentifiers: [AppIdentifier] = []

    /// Retain policies saved for helper bundle IDs before owner resolution.
    var policyIdentifiers: [AppIdentifier] { [identifier] + alternateIdentifiers }
}

enum PowerInfo {
    private static let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "power-info")

    private static let assertionTypeKey = "AssertType"
    private static let assertionLevelKey = "AssertLevel"
    private static let assertionNameKey = "AssertName"

    /// All assertion type strings that prevent the kind of sleep we care about.
    /// `NoIdleSleepAssertion` / `NoDisplaySleepAssertion` are the older
    /// (Chromium-era) aliases for the `PreventUserIdle…Sleep` types — the
    /// IOKit headers preserve both, and Vivaldi/Chrome still use the former.
    /// Display-sleep assertions count too: when the display is held awake,
    /// `powerd` registers a coordinating system-sleep assertion, so the chain
    /// transitively prevents sleep.
    private static let sleepBlockingTypes: Set<String> = [
        "PreventUserIdleSystemSleep",
        "NoIdleSleepAssertion",
        "PreventUserIdleDisplaySleep",
        "NoDisplaySleepAssertion"
    ]

    static func userIdleSeconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let nanoseconds = (prop as? NSNumber)?.int64Value else { return 0 }
        return TimeInterval(nanoseconds) / 1_000_000_000
    }

    /// Reads the currently-active system-sleep timer in seconds. Returns 0 if
    /// the user explicitly chose "Never", and `nil` if reading failed — the
    /// caller must suppress enforcement until a fresh read succeeds.
    ///
    /// Implementation note: `IOPMCopyPMPreferences` isn't surfaced in the Swift
    /// IOKit module on macOS 26, so we shell out to `pmset -g`, which already
    /// resolves to the active power source for us.
    static func activeSystemSleepTimeoutSeconds() -> TimeInterval? {
        guard let output = runPMSet(arguments: ["-g"]) else { return nil }
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // "sleep                1 (sleep prevented by …)". The trailing
            // space matters — it disambiguates from any future `sleepXxx` key.
            guard line.hasPrefix("sleep ") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "sleep", let minutes = Int(parts[1]) else { continue }
            return TimeInterval(minutes) * 60
        }
        logger.error("pmset -g output did not contain a 'sleep' line")
        return nil
    }

    private static func runPMSet(arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(filePath: "/usr/bin/pmset")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            logger.error("Failed to launch pmset: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            logger.error("pmset exited \(task.terminationStatus, privacy: .public)")
            return nil
        }
        guard let data = try? pipe.fileHandleForReading.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func activeSettings() -> PowerSettings? {
        let before = activePowerSourceKey()
        let timeout = activeSystemSleepTimeoutSeconds()
        return PowerSettings.validated(timeout: timeout, sourceBefore: before, sourceAfter: activePowerSourceKey())
    }

    static func activePowerSourceKey() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        if let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            return providing as String
        }
        return nil
    }

    /// Returns app-owned sleep-prevention assertions, including embedded
    /// background helpers. System daemons without an owning app (`powerd`,
    /// `sharingd`, `mDNSResponder`, etc.) remain excluded.
    static func assertionSnapshot() -> AssertionReadings? {
        var unmanagedDict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanagedDict) == kIOReturnSuccess,
              let raw = unmanagedDict?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return nil }

        var result: [Blocker] = []
        var reasons: [String] = []
        for (pidNum, assertions) in raw {
            let pid = pid_t(pidNum.int32Value)
            // Keep meeting signals before filtering to GUI apps: browser
            // helpers and conferencing daemons can own these assertions.
            for assertion in assertions {
                let level = (assertion[assertionLevelKey] as? NSNumber)?.intValue ?? 0
                if level > 0, let reason = assertion[assertionNameKey] as? String {
                    reasons.append(reason)
                }
            }
            let matching = assertions.filter { dict in
                let type = dict[assertionTypeKey] as? String ?? ""
                let level = (dict[assertionLevelKey] as? NSNumber)?.intValue ?? 0
                return sleepBlockingTypes.contains(type) && level > 0
            }
            guard !matching.isEmpty else { continue }
            guard let owner = assertionOwner(pid: pid) else { continue }
            for a in matching {
                let reason = (a[assertionNameKey] as? String) ?? "(unnamed)"
                result.append(Blocker(pid: pid, identifier: .bundleID(owner.bundleID),
                                      displayName: owner.displayName, reason: reason,
                                      alternateIdentifiers: owner.alternateBundleIDs.map(AppIdentifier.bundleID)))
            }
        }
        return AssertionReadings(blockers: result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }, reasons: reasons)
    }

    static func assertionOwner(pid: pid_t) -> AssertionOwner? {
        let app = NSRunningApplication(processIdentifier: pid)
        let runningIdentity = app?.bundleIdentifier.map {
            AssertionOwner(bundleID: $0, displayName: app?.localizedName ?? $0)
        }
        let executableURL = app?.executableURL ?? processExecutableURL(pid: pid)
        return AssertionOwnerResolver.resolve(runningApp: runningIdentity,
                                               executableURL: executableURL?.resolvingSymlinksInPath()) { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return AssertionOwner(bundleID: id, displayName: name)
        }
    }

    private static func processExecutableURL(pid: pid_t) -> URL? {
        // PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN), a macro Swift does not import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return URL(filePath: String(cString: buffer))
    }
}
