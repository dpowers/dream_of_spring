import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MenuContent: View {
    let enforcer: SleepEnforcer
    let launchAtLogin: LaunchAtLogin

    var body: some View {
        Text("Idle: \(format(seconds: enforcer.idleSeconds))")
        Text(timerLine)
        Text(statusLine)

        Divider()
        if enforcer.blockers.isEmpty {
            Text("Nothing is blocking sleep")
        } else {
            Text("Blocking sleep:")
            ForEach(enforcer.blockers) { blocker in
                BlockerPolicyMenu(
                    whitelist: enforcer.whitelist,
                    identifier: blocker.identifier,
                    label: "\(marker(for: enforcer.whitelist.policy(for: blocker.identifier)))  \(blocker.displayName) — \(blocker.reason)"
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
                let sorted = enforcer.whitelist.policies.keys.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                ForEach(sorted, id: \.self) { id in
                    BlockerPolicyMenu(
                        whitelist: enforcer.whitelist,
                        identifier: id,
                        label: "\(marker(for: enforcer.whitelist.policy(for: id)))  \(id.displayName) \(policySuffix(for: enforcer.whitelist.policy(for: id)))"
                    )
                }
            }
            Divider()
            Button("Add app from /Applications…") {
                addAppToWhitelistFromPicker()
            }
        }

        Divider()
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
        Button("Quit Dream Of Spring") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var timerLine: String {
        let source = enforcer.powerSource.isEmpty ? "" : " (\(enforcer.powerSource))"
        if enforcer.configuredTimeoutSeconds == 0 {
            return "Sleep timer: Never\(source)"
        }
        return "Sleep timer: \(format(seconds: enforcer.configuredTimeoutSeconds))\(source)"
    }

    private var statusLine: String {
        if enforcer.isPaused {
            if let until = enforcer.pausedUntil {
                let remaining = max(0, until.timeIntervalSinceNow)
                return "Status: paused (\(format(seconds: remaining)) left)"
            }
            return "Status: paused"
        }
        if enforcer.configuredTimeoutSeconds == 0 {
            return "Status: dormant (sleep set to Never)"
        }
        let pendingThresholds = enforcer.blockers.compactMap { blocker -> TimeInterval? in
            switch enforcer.whitelist.policy(for: blocker.identifier) {
            case .alwaysAllow: return nil
            case .allowUpTo(let s): return max(enforcer.configuredTimeoutSeconds, s)
            case nil: return enforcer.configuredTimeoutSeconds
            }
        }
        guard let earliest = pendingThresholds.min() else {
            return "Status: idle (system will sleep on its own)"
        }
        let remaining = earliest + Decider.graceSeconds - enforcer.idleSeconds
        if remaining > 0 {
            return "Status: would force sleep in \(format(seconds: remaining))"
        }
        return "Status: forcing sleep"
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
        case nil: return "•"             // counts as full blocker
        case .alwaysAllow: return "○"     // never counts
        case .allowUpTo: return "◐"        // counts after grace
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
        enforcer.whitelist.add(identifier, policy: .alwaysAllow)
    }
}

private struct BlockerPolicyMenu: View {
    let whitelist: Whitelist
    let identifier: AppIdentifier
    let label: String

    var body: some View {
        Menu {
            let current = whitelist.policy(for: identifier)
            Button(check(current == nil) + "Don't whitelist") {
                whitelist.remove(identifier)
            }
            Button(check(current == .alwaysAllow) + "Always allow") {
                whitelist.setPolicy(.alwaysAllow, for: identifier)
            }
            Divider()
            ForEach(WhitelistPreset.allowUpToOptions, id: \.label) { preset in
                let isSelected = current == .allowUpTo(seconds: preset.seconds)
                Button(check(isSelected) + "Allow up to \(preset.label)") {
                    whitelist.setPolicy(.allowUpTo(seconds: preset.seconds), for: identifier)
                }
            }
        } label: {
            Text(label)
        }
    }

    private func check(_ on: Bool) -> String { on ? "✓ " : "   " }
}
