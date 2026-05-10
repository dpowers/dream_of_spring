import SwiftUI

@main
struct Dream_Of_SpringApp: App {
    @State private var enforcer = SleepEnforcer(requestSleep: { SleepActuator.sleepNow() })
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(enforcer: enforcer, launchAtLogin: launchAtLogin)
        } label: {
            Image(systemName: iconName)
        }
    }

    private var iconName: String {
        if enforcer.isPaused { return "moon" }
        if enforcer.nonWhitelistedBlockers.isEmpty { return "moon.zzz" }
        return "moon.zzz.fill"
    }
}
