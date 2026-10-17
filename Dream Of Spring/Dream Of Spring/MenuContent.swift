import AppKit
import UniformTypeIdentifiers

/// Populate once per opening. Live Observation updates must not replace menu
/// items while AppKit is tracking the pointer through a submenu.
@MainActor
final class MenuContent: NSObject, NSMenuDelegate {
    let enforcer: SleepEnforcer
    let launchAtLogin: LaunchAtLogin
    let menu = NSMenu()

    init(enforcer: SleepEnforcer, launchAtLogin: LaunchAtLogin) {
        self.enforcer = enforcer
        self.launchAtLogin = launchAtLogin
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        launchAtLogin.refresh()
        menu.removeAllItems()
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.addText("Idle: \(format(seconds: enforcer.idleSeconds))")
        menu.addText(timerLine)
        if let battery = enforcer.battery {
            menu.addText("Battery: \(Int(battery.percentage.rounded()))%\(battery.isOnBatteryPower ? "" : " (external power)")")
        }
        if enforcer.batteryPlan != nil {
            menu.addText("Preserving a \(Int(enforcer.batteryPreferences.reservePercentage))% reserve")
            menu.addText("Human interaction resets the battery allowance")
        }
        menu.addText(statusLine)
        if !enforcer.closedLidPreferences.permissions.isEmpty {
            menu.addText(enforcer.closedLidStatus)
            if enforcer.closedLidLeaseSeconds > 0 || enforcer.closedLidController.isActive {
                menu.addText("To sleep during protected work, choose Sleep Now here.")
            }
        }
        if enforcer.isCaptureProtected && enforcer.batteryIdleLimitSeconds == nil {
            menu.addText("Capture wait started by: \(enforcer.lastCaptureResetReason)")
        }

        menu.addItem(.separator())
        if enforcer.blockers.isEmpty {
            menu.addText("Nothing is blocking sleep")
        } else {
            menu.addText("Blocking sleep:")
            for blocker in enforcer.blockers {
                let label = "\(marker(for: enforcer.whitelist.policy(for: blocker.policyIdentifiers)))  \(blocker.displayName) — \(blocker.reason)"
                addPolicyMenu(to: menu, identifier: blocker.identifier,
                              alternateIdentifiers: blocker.alternateIdentifiers, label: label)
            }
        }

        menu.addItem(.separator())
        if enforcer.isPaused {
            menu.addAction("Resume forced sleep") { [enforcer] in enforcer.resume() }
        } else {
            let pause = menu.addSubmenu("Pause forced sleep")
            pause.addAction("Pause for 15 minutes") { [enforcer] in enforcer.pause(for: 15 * 60) }
            pause.addAction("Pause for 1 hour") { [enforcer] in enforcer.pause(for: 60 * 60) }
            pause.addAction("Pause until I resume") { [enforcer] in enforcer.pause(for: nil) }
        }

        let policies = menu.addSubmenu("App policies")
        let savedIDs = Set(enforcer.whitelist.policies.keys).union(enforcer.closedLidPreferences.permissions.keys)
        if savedIDs.isEmpty {
            policies.addText("No saved app policies")
        } else {
            let sorted = savedIDs
                .map { (id: $0, name: $0.displayName) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            for entry in sorted {
                let policy = enforcer.whitelist.policy(for: entry.id)
                addPolicyMenu(to: policies, identifier: entry.id,
                              label: "\(marker(for: policy))  \(entry.name) \(policySuffix(for: policy))")
            }
        }
        policies.addItem(.separator())
        policies.addAction("Add app from /Applications…") { [weak self] in
            self?.addAppToWhitelistFromPicker()
        }

        if enforcer.closedLidController.needsApproval {
            menu.addAction("Approve closed-lid access in System Settings…") { [enforcer] in
                enforcer.closedLidController.openApprovalSettings()
            }
        } else if enforcer.closedLidController.hasFailure {
            menu.addText(enforcer.closedLidController.message)
        }
        menu.addAction("Sleep Now") { [enforcer] in enforcer.sleepNow() }

        menu.addItem(.separator())
        addBatteryMenu(to: menu)
        menu.addAction("Launch at Login", checked: launchAtLogin.isEnabled) { [launchAtLogin] in
            launchAtLogin.toggle()
        }
        menu.addAction("Open Energy Saver Settings…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
                NSWorkspace.shared.open(url)
            }
        }
        menu.addItem(.separator())
        menu.addText("Version \(appVersion)")
        menu.addAction("Copy Sleep Diagnostics") { [enforcer] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(enforcer.diagnostics, forType: .string)
        }
        menu.addAction("Quit Dream Of Spring", keyEquivalent: "q") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func addBatteryMenu(to menu: NSMenu) {
        let battery = menu.addSubmenu("Battery Protection")
        battery.addAction("Preserve battery when unattended", checked: enforcer.batteryPreferences.isEnabled) { [enforcer] in
            enforcer.batteryPreferences.isEnabled.toggle()
            enforcer.batterySettingsChanged()
        }
        let reserve = battery.addSubmenu("Reserve target", enabled: enforcer.batteryPreferences.isEnabled)
        for value in [15.0, 20.0, 25.0, 30.0] {
            reserve.addAction("\(Int(value))%\(value == 20 ? " (recommended)" : "")",
                              checked: enforcer.batteryPreferences.reservePercentage == value) { [enforcer] in
                enforcer.batteryPreferences.setReservePercentage(value)
                enforcer.batterySettingsChanged()
            }
        }
        battery.addItem(.separator())
        battery.addText("On battery, at \(Int(enforcer.batteryPreferences.reservePercentage + 10))%: up to 30 min unattended")
        battery.addText("At the reserve target: 10 min · At 10%: 3 min · At 5%: 1 min")
        battery.addText("Faster drain can shorten the 30-minute allowance")
        battery.addText("Limits override pauses, whitelists, and calls")
        if let rate = enforcer.batteryDrainPerHour {
            battery.addItem(.separator())
            battery.addText("Recent drain: ~\(String(format: "%.1f", rate)) percentage points/hour")
        }
        if let plan = enforcer.batteryPlan {
            battery.addText("Without interaction: \(format(seconds: plan.remainingSeconds)) remaining")
            if plan.reason == .approachingReserve {
                battery.addText("Allowance shortened to protect your reserve")
            }
        }
    }

    private func addPolicyMenu(to menu: NSMenu, identifier: AppIdentifier,
                               alternateIdentifiers: [AppIdentifier] = [], label: String) {
        let policyMenu = menu.addSubmenu(label)
        let identifiers = [identifier] + alternateIdentifiers
        let current = enforcer.whitelist.policy(for: identifiers)
        let lidPermission = enforcer.closedLidPreferences.permission(for: identifiers)
        policyMenu.addAction("Allow keeping awake with lid closed", checked: lidPermission != nil) { [enforcer] in
            let enabled = enforcer.closedLidPreferences.permission(for: identifiers) == nil
            enforcer.closedLidPreferences.set(enabled ? ClosedLidPermission() : nil,
                for: identifier, replacing: alternateIdentifiers)
            enforcer.closedLidSettingsChanged()
        }
        if let lidPermission {
            policyMenu.addAction("Only on external power", checked: lidPermission.onlyOnExternalPower) { [enforcer] in
                guard let permission = enforcer.closedLidPreferences.permission(for: identifiers) else { return }
                enforcer.closedLidPreferences.set(ClosedLidPermission(onlyOnExternalPower: !permission.onlyOnExternalPower),
                    for: identifier, replacing: alternateIdentifiers)
                enforcer.closedLidSettingsChanged()
            }
            policyMenu.addText("While this program holds a system-sleep assertion.")
            policyMenu.addText("Battery protection still applies.")
        }
        policyMenu.addItem(.separator())
        policyMenu.addAction("Don't whitelist", checked: current == nil) { [enforcer] in
            enforcer.whitelist.setPolicy(nil, for: identifier, replacing: alternateIdentifiers)
            enforcer.tick()
        }
        policyMenu.addAction("Always allow", checked: current == .alwaysAllow) { [enforcer] in
            enforcer.whitelist.setPolicy(.alwaysAllow, for: identifier, replacing: alternateIdentifiers)
            enforcer.tick()
        }
        policyMenu.addItem(.separator())
        for preset in WhitelistPreset.allowUpToOptions {
            policyMenu.addAction("Allow up to \(preset.label)", checked: current == .allowUpTo(seconds: preset.seconds)) { [enforcer] in
                enforcer.whitelist.setPolicy(.allowUpTo(seconds: preset.seconds), for: identifier, replacing: alternateIdentifiers)
                enforcer.tick()
            }
        }
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
        if enforcer.closedLidLeaseSeconds > 0 {
            return "Status: allowed app is requesting continued background work"
        }
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

/// NSMenuItem's target is weak; the item owns its action so it lives exactly as
/// long as the snapshot. Actions that need the menu controller capture it weakly.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performAction), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func performAction() { handler() }
}

@MainActor
private extension NSMenu {
    func addText(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    func addAction(_ title: String, checked: Bool = false, keyEquivalent: String = "",
                   handler: @escaping () -> Void) {
        let item = ActionMenuItem(title: title, keyEquivalent: keyEquivalent, handler: handler)
        item.state = checked ? .on : .off
        addItem(item)
    }

    func addSubmenu(_ title: String, enabled: Bool = true) -> NSMenu {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = enabled
        addItem(item)
        return submenu
    }
}
