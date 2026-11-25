//
//  SleepTimerController.swift
//  Dream Of Spring
//
import Foundation
import Observation
import OSLog
import ServiceManagement

/// Reads the per-power-source system-sleep timers (unprivileged) and changes
/// them through the privileged helper's fixed `setSleepTimer` operation.
@MainActor @Observable
final class SleepTimerController {
    typealias Reply = @MainActor (Bool, String) -> Void
    typealias Transport = @MainActor (Int, SleepTimerSource, @escaping Reply) -> Void

    private(set) var settings: SleepTimerSettings?
    /// Most recent failure, cleared by the next successful change.
    private(set) var failure: String?
    private(set) var isChanging = false
    private let readSettings: @MainActor () -> SleepTimerSettings?
    private let transport: Transport?
    private let readServiceStatus: @MainActor () -> SMAppService.Status
    private var generation = 0

    init(disabled: Bool = EnforcementRuntime.isDisabled,
         readSettings: (@MainActor () -> SleepTimerSettings?)? = nil,
         transport: Transport? = nil,
         readServiceStatus: @MainActor @escaping () -> SMAppService.Status = {
             SMAppService.daemon(plistName: ClosedLidService.plistName).status
         }) {
        // A disabled runtime (tests, --disable-sleep-enforcement) must never
        // touch the real power settings unless a fake transport is injected.
        if let readSettings {
            self.readSettings = readSettings
        } else if disabled {
            self.readSettings = { @MainActor in nil }
        } else {
            self.readSettings = { @MainActor in PowerInfo.sleepTimerSettings() }
        }
        if let transport {
            self.transport = transport
        } else if disabled {
            self.transport = { @MainActor _, _, reply in
                reply(false, "Changing sleep timers is disabled in this session")
            }
        } else {
            self.transport = nil
        }
        self.readServiceStatus = readServiceStatus
    }

    func refresh() {
        settings = readSettings()
    }

    func set(minutes: Int, for source: SleepTimerSource, completion: @escaping @MainActor () -> Void = {}) {
        guard SleepTimerSettings.isValid(minutes: minutes) else { return }
        guard !isChanging else { return }
        if transport == nil {
            let status = readServiceStatus()
            guard status == .enabled else {
                failure = status == .requiresApproval
                    ? "Approve Dream Of Spring in System Settings → Login Items to change sleep timers"
                    : "The helper is unavailable; relaunch the installed app to retry setup"
                return
            }
        }
        isChanging = true
        generation += 1
        let ticket = generation
        let reply: Reply = { [weak self] success, detail in
            guard let self, self.isChanging, self.generation == ticket else { return }
            self.isChanging = false
            self.failure = success ? nil : (detail.isEmpty ? "Could not change the sleep timer" : detail)
            self.refresh()
            completion()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard self?.generation == ticket else { return }
            reply(false, "The helper did not respond to the sleep timer change")
        }
        if let transport {
            transport(minutes, source, reply)
        } else {
            Self.sendToHelper(minutes: minutes, source: source, reply: reply)
        }
    }

    private static func sendToHelper(minutes: Int, source: SleepTimerSource, reply: @escaping Reply) {
        guard let requirement = ClosedLidService.helperRequirement else {
            reply(false, "Changing sleep timers requires a signed app")
            return
        }
        let connection = NSXPCConnection(machServiceName: ClosedLidService.name, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: ClosedLidServiceProtocol.self)
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "sleep-timers")
                .error("Sleep timer XPC failed: \(String(describing: error), privacy: .public)")
            Task { @MainActor in
                connection.invalidate()
                // An older helper still running after an update lacks this
                // operation; relaunching restarts it with the new binary.
                reply(false, "Helper: \(error.localizedDescription)")
            }
        } as? ClosedLidServiceProtocol
        proxy?.setSleepTimer(minutes: minutes, source: source.rawValue) { success, detail in
            Task { @MainActor in
                connection.invalidate()
                reply(success, detail)
            }
        }
    }
}
