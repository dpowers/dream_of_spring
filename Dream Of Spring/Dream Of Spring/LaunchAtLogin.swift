import Foundation
import Observation
import ServiceManagement
import os

@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled: Bool = false

    private static let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "launch-at-login")
    private static let pollInterval: Duration = .seconds(30)

    init() {
        refresh()
        // Pick up changes made outside the app (System Settings → General →
        // Login Items) so the menu toggle stays accurate without requiring a
        // relaunch. 30 s matches the enforcer's cadence.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: LaunchAtLogin.pollInterval)
                self?.refresh()
            }
        }
    }

    func refresh() {
        // Guard against same-value writes — @Observable fires observers on
        // every assignment, not just changes, and we don't want every 30 s
        // refresh to trigger a SwiftUI re-render when nothing actually moved.
        let current = SMAppService.mainApp.status == .enabled
        if current != isEnabled {
            isEnabled = current
        }
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
