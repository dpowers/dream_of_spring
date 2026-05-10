import Foundation
import Observation
import ServiceManagement
import os

@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled: Bool = false

    private static let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "launch-at-login")

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Self.logger.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
