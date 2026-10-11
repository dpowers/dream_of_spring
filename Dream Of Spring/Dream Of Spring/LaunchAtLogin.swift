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

    private let readStatus: @MainActor () -> SMAppService.Status
    private let register: @MainActor () throws -> Void
    private let unregister: @MainActor () throws -> Void
    private let openSettings: @MainActor () -> Void

    init(
        startAutomatically: Bool = true,
        readStatus: @MainActor @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @MainActor @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @MainActor @escaping () throws -> Void = { try SMAppService.mainApp.unregister() },
        openSettings: @MainActor @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        self.openSettings = openSettings
        refresh()
        guard startAutomatically else { return }
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
        let current = readStatus() == .enabled
        if current != isEnabled {
            isEnabled = current
        }
    }

    func toggle() {
        do {
            switch readStatus() {
            case .enabled:
                try unregister()
            case .requiresApproval:
                // Already registered, but disabled by the user in Settings.
                // Registering again cannot grant approval.
                break
            default:
                try register()
            }
        } catch {
            Self.logger.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        if readStatus() == .requiresApproval {
            openSettings()
        }
        refresh()
    }
}
