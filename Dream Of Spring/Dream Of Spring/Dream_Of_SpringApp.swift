import SwiftUI
import Observation

@main
struct Dream_Of_SpringApp: App {
    @NSApplicationDelegateAdaptor(SleepApplicationDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class SleepApplicationDelegate: NSObject, NSApplicationDelegate {
    private var enforcer: SleepEnforcer?
    private var menuContent: MenuContent?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let enforcer = SleepEnforcer(startAutomatically: !EnforcementRuntime.isDisabled,
                                     requestSleep: { SleepActuator.sleepNow() })
        self.enforcer = enforcer
        let content = MenuContent(enforcer: enforcer, launchAtLogin: LaunchAtLogin())
        menuContent = content
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = content.menu
        item.button?.setAccessibilityLabel("Dream Of Spring")
        statusItem = item
        updateIcon()
    }

    /// Observe only the icon here. Updating the status button never rebuilds
    /// the menu that AppKit is currently tracking.
    private func updateIcon() {
        let name = withObservationTracking {
            iconName
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Dream Of Spring")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    private var iconName: String {
        guard let enforcer else { return "moon.zzz" }
        if enforcer.batteryIdleLimitSeconds != nil { return "moon.zzz.fill" }
        if enforcer.closedLidController.isActive { return "laptopcomputer" }
        if enforcer.isPaused { return "moon" }
        if enforcer.nonAlwaysAllowedBlockers.isEmpty { return "moon.zzz" }
        return "moon.zzz.fill"
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let enforcer else { return .terminateNow }
        // The completion can be synchronous when no override is held.
        Task { @MainActor in
            enforcer.prepareForTermination { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
