import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MenuContent: View {
    let enforcer: SleepEnforcer
    let launchAtLogin: LaunchAtLogin

    var body: some View {
        Text("Idle: \(format(seconds: enforcer.idleSeconds))")
        Text(timerLine)
        if let battery = enforcer.battery {
            Text("Battery: \(Int(battery.percentage.rounded()))%\(battery.isOnBatteryPower ? "" : " (external power)")")
        }
        if enforcer.batteryPlan != nil {
            Text("Preserving a \(Int(enforcer.batteryPreferences.reservePercentage))% reserve")
            Text("Human interaction resets the battery allowance")
        }
        Text(statusLine)
        if enforcer.isCaptureProtected && enforcer.batteryIdleLimitSeconds == nil {
            Text("Capture wait started by: \(enforcer.lastCaptureResetReason)")
        }

        Divider()
        if enforcer.blockers.isEmpty {
            Text("Nothing is blocking sleep")
        } else {
            Text("Blocking sleep:")
            ForEach(enforcer.blockers) { blocker in
                BlockerPolicyMenu(
                    whitelist: enforcer.whitelist,
                    identifier: blocker.identifier,
                    alternateIdentifiers: blocker.alternateIdentifiers,
                    label: "\(marker(for: enforcer.whitelist.policy(for: blocker.policyIdentifiers)))  \(blocker.displayName) — \(blocker.reason)"
                )
            }
        }

        Divider()
        if enforcer.isPaused {
            Button("Resume Dream Of Spring") {
                enforcer.resume()
            }
        } else {
            Menu("Pause") {
                Button("Pause for 15 minutes") { enforcer.pause(for: 15 * 60) }
                Button("Pause for 1 hour") { enforcer.pause(for: 60 * 60) }
                Button("Pause until I resume") { enforcer.pause(for: nil) }
            }
        }

        Menu("Whitelist") {
            if enforcer.whitelist.policies.isEmpty {
                Text("No apps whitelisted")
            } else {
                // Resolve displayName once per id; `displayName` does a linear
                // scan of running applications, so doing it inside a sort
                // comparator would be O(N log N) scans.
                let sorted = enforcer.whitelist.policies.keys
                    .map { (id: $0, name: $0.displayName) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                ForEach(sorted, id: \.id) { entry in
                    let policy = enforcer.whitelist.policy(for: entry.id)
                    BlockerPolicyMenu(
                        whitelist: enforcer.whitelist,
                        identifier: entry.id,
                        label: "\(marker(for: policy))  \(entry.name) \(policySuffix(for: policy))"
                    )
                }
            }
            Divider()
            Button("Add app from /Applications…") {
                addAppToWhitelistFromPicker()
            }
        }

        Divider()
        Menu("Battery Protection") {
            Toggle("Preserve battery when unattended", isOn: Binding(
                get: { enforcer.batteryPreferences.isEnabled },
                set: { enforcer.batteryPreferences.isEnabled = $0; enforcer.batterySettingsChanged() }
            ))
            Picker("Reserve target", selection: Binding(
                get: { enforcer.batteryPreferences.reservePercentage },
                set: { enforcer.batteryPreferences.setReservePercentage($0); enforcer.batterySettingsChanged() }
            )) {
                ForEach([15.0, 20.0, 25.0, 30.0], id: \.self) { value in
                    Text("\(Int(value))%\(value == 20 ? " (recommended)" : "")").tag(value)
                }
            }
            .disabled(!enforcer.batteryPreferences.isEnabled)
            Divider()
            Text("On battery, at \(Int(enforcer.batteryPreferences.reservePercentage + 10))%: up to 30 min unattended")
            Text("At the reserve target: 10 min · At 10%: 3 min · At 5%: 1 min")
            Text("Faster drain can shorten the 30-minute allowance")
            Text("Limits override pauses, whitelists, and calls")
            if let rate = enforcer.batteryDrainPerHour {
                Divider()
                Text("Recent drain: ~\(String(format: "%.1f", rate)) percentage points/hour")
            }
            if let plan = enforcer.batteryPlan {
                Text("Without interaction: \(format(seconds: plan.remainingSeconds)) remaining")
                if plan.reason == .approachingReserve {
                    Text("Allowance shortened to protect your reserve")
                }
            }
        }

        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { _ in launchAtLogin.toggle() }
        ))
        Button("Open Energy Saver Settings…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
                NSWorkspace.shared.open(url)
            }
        }

        Divider()
        Text("Version \(appVersion)")
        Button("Copy Sleep Diagnostics") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(enforcer.diagnostics, forType: .string)
        }
        Button("Quit Dream Of Spring") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var timerLine: String {
        guard enforcer.hasValidSettings else { return "Sleep timer: unavailable" }
        let source = enforcer.powerSource.isEmpty ? "" : " (\(enforcer.powerSource))"
        if enforcer.configuredTimeoutSeconds == 0 {
            return "Sleep timer: Never\(source)"
        }
        return "Sleep timer: \(format(seconds: enforcer.configuredTimeoutSeconds))\(source)"
    }

    private var statusLine: String {
        if enforcer.batteryPlan != nil, let remaining = enforcer.effectiveSleepRemainingSeconds {
            if enforcer.lastActuatorFailed {
                return "Status: ⚠ last sleep attempt failed (see Console.app)"
            }
            return remaining > 0
                ? "Status: reserve protection — sleep in \(format(seconds: remaining))"
                : "Status: battery protection — requesting sleep"
        }
        // Paused / dormant / on-a-call are the truthful state when the
        // enforcer isn't acting, so they take priority over a (possibly
        // stale) failure flag.
        if enforcer.isPaused {
            if let until = enforcer.pausedUntil {
                let remaining = max(0, until.timeIntervalSinceNow)
                return "Status: paused (\(format(seconds: remaining)) left)"
            }
            return "Status: paused"
        }
        if !enforcer.hasValidSettings {
            return "Status: waiting for current power settings — won't force sleep"
        }
        if enforcer.configuredTimeoutSeconds == 0 {
            return "Status: dormant (sleep set to Never)"
        }
        if enforcer.meetingActivity == .active {
            return "Status: meeting app or screen sharing detected — won't force sleep"
        }
        if enforcer.meetingActivity == .unknown {
            return "Status: meeting activity unavailable — won't force sleep"
        }
        if enforcer.cameraInUse || enforcer.microphoneInUse {
            return "Status: \(captureDescription) in use — won't force sleep"
        }
        if enforcer.cameraActivity == .unknown || enforcer.microphoneActivity == .unknown {
            return "Status: capture activity unavailable — won't force sleep"
        }
        if enforcer.isCaptureProtected {
            return "Status: camera and microphone inactive — safety wait \(format(seconds: enforcer.captureQuietSecondsRemaining))"
        }
        if enforcer.isMeetingProtected {
            return "Status: meeting activity inactive — safety wait \(format(seconds: enforcer.meetingQuietSecondsRemaining))"
        }
        if enforcer.lastActuatorFailed {
            return "Status: ⚠ last sleep attempt failed (see Console.app)"
        }
        guard let deadline = enforcer.sleepDeadlineSeconds else {
            return "Status: idle (system will sleep on its own)"
        }
        guard deadline.isFinite else {
            return "Status: whitelisted app is keeping the Mac awake"
        }
        let remaining = deadline - enforcer.idleSeconds
        if remaining > 0 {
            return "Status: would force sleep in \(format(seconds: remaining))"
        }
        return "Status: forcing sleep"
    }

    /// Stamped with the build date (YYYY-MM-DD) by the "Stamp version with
    /// build date" run-script phase.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private var captureDescription: String {
        switch (enforcer.cameraInUse, enforcer.microphoneInUse) {
        case (true, true): return "camera & microphone"
        case (true, false): return "camera"
        default: return "microphone"
        }
    }

    private func format(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let m = total / 60
        let s = total % 60
        if s == 0 { return "\(m) min" }
        return "\(m) min \(s) s"
    }

    private func marker(for policy: WhitelistPolicy?) -> String {
        switch policy {
        case nil: return "•"
        case .alwaysAllow: return "○"
        case .allowUpTo: return "◐"
        }
    }

    private func policySuffix(for policy: WhitelistPolicy?) -> String {
        switch policy {
        case .allowUpTo(let s): return "(allow up to \(format(seconds: s)))"
        case .alwaysAllow: return "(always allow)"
        case nil: return ""
        }
    }

    private func addAppToWhitelistFromPicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Whitelist an app"
        panel.message = "Pick an app you want to allow to keep your Mac awake."
        panel.prompt = "Whitelist"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let identifier: AppIdentifier
        if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
            identifier = .bundleID(bid)
        } else {
            identifier = .processName(url.deletingPathExtension().lastPathComponent)
        }
        enforcer.whitelist.setPolicy(.alwaysAllow, for: identifier)
    }
}

private struct BlockerPolicyMenu: View {
    let whitelist: Whitelist
    let identifier: AppIdentifier
    var alternateIdentifiers: [AppIdentifier] = []
    let label: String

    var body: some View {
        Menu {
            let current = whitelist.policy(for: [identifier] + alternateIdentifiers)
            Button(check(current == nil) + "Don't whitelist") {
                whitelist.setPolicy(nil, for: identifier, replacing: alternateIdentifiers)
            }
            Button(check(current == .alwaysAllow) + "Always allow") {
                whitelist.setPolicy(.alwaysAllow, for: identifier, replacing: alternateIdentifiers)
            }
            Divider()
            ForEach(WhitelistPreset.allowUpToOptions, id: \.label) { preset in
                let isSelected = current == .allowUpTo(seconds: preset.seconds)
                Button(check(isSelected) + "Allow up to \(preset.label)") {
                    whitelist.setPolicy(.allowUpTo(seconds: preset.seconds), for: identifier, replacing: alternateIdentifiers)
                }
            }
        } label: {
            Text(label)
        }
    }

    private func check(_ on: Bool) -> String { on ? "✓ " : "   " }
}
