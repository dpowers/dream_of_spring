import SwiftUI

@main
struct Dream_Of_SpringApp: App {
    @NSApplicationDelegateAdaptor(SleepApplicationDelegate.self) private var delegate
    @State private var enforcer: SleepEnforcer
    @State private var launchAtLogin = LaunchAtLogin()

    init() {
        let instance = SleepEnforcer(startAutomatically: !EnforcementRuntime.isDisabled, requestSleep: { SleepActuator.sleepNow() })
        _enforcer = State(initialValue: instance)
        SleepApplicationDelegate.enforcer = instance
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(enforcer: enforcer, launchAtLogin: launchAtLogin)
        } label: {
            Image(systemName: iconName)
        }
    }

    private var iconName: String {
        if enforcer.batteryIdleLimitSeconds != nil { return "moon.zzz.fill" }
        if enforcer.closedLidController.isActive { return "laptopcomputer" }
        if enforcer.isPaused { return "moon" }
        if enforcer.nonAlwaysAllowedBlockers.isEmpty { return "moon.zzz" }
        return "moon.zzz.fill"
    }
}

@MainActor
final class SleepApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var enforcer: SleepEnforcer?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let enforcer = Self.enforcer else { return .terminateNow }
        // The completion can be synchronous when no override is held.
        Task { @MainActor in
            enforcer.prepareForTermination { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
