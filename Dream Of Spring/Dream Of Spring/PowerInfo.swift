import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import AppKit

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
}

enum PowerInfo {
    private static let assertionTypeKey = "AssertType"
    private static let assertionLevelKey = "AssertLevel"
    private static let assertionNameKey = "AssertName"
    private static let acPower = "AC Power"
    private static let systemSleepKey = "System Sleep Timer"

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

    /// Reads the currently-active system-sleep timer in seconds.
    /// Returns 0 if the user has selected "Never".
    /// Implementation note: `IOPMCopyPMPreferences` isn't surfaced in the Swift
    /// IOKit module on macOS 26, so we shell out to `pmset -g`, which already
    /// resolves to the active power source for us.
    static func activeSystemSleepTimeoutSeconds() -> TimeInterval {
        guard let output = runPMSet(arguments: ["-g"]) else { return 0 }
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // "sleep                1 (sleep prevented by …)"
            guard line.hasPrefix("sleep") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "sleep", let minutes = Int(parts[1]) else { continue }
            return TimeInterval(minutes) * 60
        }
        return 0
    }

    private static func runPMSet(arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(filePath: "/usr/bin/pmset")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func activePowerSourceKey() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return acPower }
        if let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            return providing as String
        }
        return acPower
    }

    /// Returns the set of GUI apps currently holding any sleep-prevention
    /// assertion. System daemons without a bundle identifier (`powerd`,
    /// `sharingd`, `mDNSResponder`, etc.) are deliberately excluded — the
    /// user's policy is "ignore apps that prevent sleep", and macOS's own
    /// coordinating assertions are not in scope.
    static func blockingAssertions() -> [Blocker] {
        var unmanagedDict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanagedDict) == kIOReturnSuccess,
              let raw = unmanagedDict?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }

        var result: [Blocker] = []
        for (pidNum, assertions) in raw {
            let pid = pid_t(pidNum.int32Value)
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bid = app.bundleIdentifier else { continue }
            let matching = assertions.filter { dict in
                let type = dict[assertionTypeKey] as? String ?? ""
                let level = (dict[assertionLevelKey] as? NSNumber)?.intValue ?? 0
                return sleepBlockingTypes.contains(type) && level > 0
            }
            guard !matching.isEmpty else { continue }
            let identifier: AppIdentifier = .bundleID(bid)
            let name = app.localizedName ?? bid
            for a in matching {
                let reason = (a[assertionNameKey] as? String) ?? "(unnamed)"
                result.append(Blocker(pid: pid, identifier: identifier, displayName: name, reason: reason))
            }
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
