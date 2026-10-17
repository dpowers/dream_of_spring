//
//  ClosedLidController.swift
//  Dream Of Spring
//
import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class ClosedLidController {
    typealias Reply = @MainActor (Bool, String) -> Void
    typealias Transport = @MainActor (Double, Bool, Bool, Double, @escaping Reply) -> Void

    private(set) var isActive = false
    private(set) var message = "Closed-lid support is not enabled"
    private(set) var needsApproval = false
    private(set) var hasFailure = false
    private let disabled: Bool
    private let transport: Transport?
    private var connection: NSXPCConnection?
    private var generation = 0
    private var inFlight = false
    private var pending = Request(seconds: 0, allowOnBattery: false, protectBattery: true, reserve: 20)
    private var releaseWaiters: [Reply] = []
    private var possiblyActiveUntil: TimeInterval = 0
    private var timeoutTask: Task<Void, Never>?

    private struct Request: Equatable {
        var seconds: Double
        var allowOnBattery: Bool
        var protectBattery: Bool
        var reserve: Double
    }

    init(disabled: Bool = EnforcementRuntime.isDisabled, transport: Transport? = nil) {
        self.disabled = disabled
        self.transport = transport
    }

    func enableSupport() {
        guard !disabled else { return }
        let service = SMAppService.daemon(plistName: ClosedLidService.plistName)
        do {
            if service.status == .notRegistered { try service.register() }
            needsApproval = service.status == .requiresApproval
            if needsApproval {
                message = "Approve Dream Of Spring in Login Items to enable closed-lid support"
                SMAppService.openSystemSettingsLoginItems()
            } else if service.status == .enabled {
                message = "Ready — waiting for an allowed app's system-sleep assertion"
            } else {
                message = "Closed-lid helper is unavailable; install the app in Applications"
            }
        } catch { message = "Could not enable closed-lid support: \(error.localizedDescription)" }
    }

    func update(seconds: Double, allowOnBattery: Bool = false, protectBattery: Bool, reserve: Double) {
        pending = Request(seconds: seconds, allowOnBattery: allowOnBattery, protectBattery: protectBattery, reserve: reserve)
        sendPending()
    }

    /// Sleep must wait for restoration of SleepDisabled, rather than racing it.
    func releaseForSleep(_ reply: @escaping Reply) {
        pending.seconds = 0
        releaseWaiters.append(reply)
        sendPending()
    }

    private func sendPending() {
        guard !inFlight else { return }
        if !releaseWaiters.isEmpty { pending.seconds = 0 }
        let request = pending
        if disabled {
            finishRelease(success: true, message: "")
            return
        }
        if request.seconds == 0 && !isActive && possiblyActiveUntil <= ProcessInfo.processInfo.systemUptime {
            finishRelease(success: true, message: "")
            return
        }
        if transport == nil {
            let status = SMAppService.daemon(plistName: ClosedLidService.plistName).status
            needsApproval = status == .requiresApproval
            guard status == .enabled else {
                message = needsApproval ? "Closed-lid support needs approval in Login Items" : "Enable closed-lid support to protect this work"
                isActive = false
                finishRelease(success: possiblyActiveUntil <= ProcessInfo.processInfo.systemUptime, message: message)
                return
            }
        }
        inFlight = true
        generation += 1
        let ticket = generation
        if request.seconds > 0 {
            possiblyActiveUntil = ProcessInfo.processInfo.systemUptime + ClosedLidService.maximumLeaseSeconds
        }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.inFlight, self.generation == ticket else { return }
            self.connection?.invalidate()
            self.connection = nil
            self.complete(ticket: ticket, request: request, success: false,
                detail: "Closed-lid helper did not respond; its protection expires automatically")
        }
        let reply: Reply = { [weak self] success, detail in
            self?.complete(ticket: ticket, request: request, success: success, detail: detail)
        }
        if let transport {
            transport(request.seconds, request.allowOnBattery, request.protectBattery, request.reserve, reply)
        } else {
            if connection == nil {
                guard let requirement = ClosedLidService.helperRequirement else {
                    complete(ticket: ticket, request: request, success: false, detail: "Closed-lid support requires a signed app")
                    return
                }
                let client = NSXPCConnection(machServiceName: ClosedLidService.name, options: .privileged)
                client.setCodeSigningRequirement(requirement)
                client.remoteObjectInterface = NSXPCInterface(with: ClosedLidServiceProtocol.self)
                client.resume()
                connection = client
            }
            let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
                Task { @MainActor in reply(false, "Closed-lid helper: \(error.localizedDescription)") }
            } as? ClosedLidServiceProtocol
            proxy?.setLease(seconds: request.seconds, allowOnBattery: request.allowOnBattery, protectBattery: request.protectBattery,
                reserve: request.reserve) { success, detail in
                    Task { @MainActor in reply(success, detail) }
                }
        }
    }

    private func complete(ticket: Int, request: Request, success: Bool, detail: String) {
        guard inFlight, generation == ticket else { return }
        timeoutTask?.cancel()
        inFlight = false
        isActive = success && request.seconds > 0
        hasFailure = !success
        message = success ? (isActive ? "Closed-lid protection active" : "Closed-lid protection released") : detail
        if success && request.seconds == 0 { possiblyActiveUntil = 0 }
        if !success {
            connection?.invalidate()
            connection = nil
        }
        if request.seconds == 0 { finishRelease(success: success, message: detail) }
        // A release requested while a renewal was in flight must be sent even
        // if that renewal failed: its effect on the system may be uncertain.
        if pending != request || !releaseWaiters.isEmpty { sendPending() }
    }

    private func finishRelease(success: Bool, message: String) {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter(success, message) }
    }
}
