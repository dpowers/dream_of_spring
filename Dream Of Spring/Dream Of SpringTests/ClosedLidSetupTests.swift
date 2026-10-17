//
//  ClosedLidSetupTests.swift
//  Dream Of SpringTests
//
import ServiceManagement
import Foundation
import Testing
@testable import Dream_Of_Spring

@MainActor
struct ClosedLidSetupTests {
    @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
    func startupRegistersWithoutOpeningSettingsAndPicksUpApprovalWhileIdle(initialStatus: SMAppService.Status) {
        var status = initialStatus
        var registrations = 0
        var settingsOpens = 0
        let controller = ClosedLidController(disabled: false,
            readServiceStatus: { status },
            registerService: { registrations += 1; status = .requiresApproval },
            openSettings: { settingsOpens += 1 })
        controller.prepareSupport()
        #expect(registrations == 1)
        #expect(controller.needsApproval)
        #expect(settingsOpens == 0)
        controller.prepareSupport()
        #expect(registrations == 1, "Do not repeatedly register a service awaiting OS approval")
        controller.openApprovalSettings()
        #expect(settingsOpens == 1)
        status = .enabled
        controller.update(seconds: 0, protectBattery: true, reserve: 20)
        #expect(!controller.needsApproval)
        #expect(!controller.hasFailure)
        #expect(controller.message.hasPrefix("Ready"))
        #expect(!controller.isActive, "Automatic setup alone must never prevent sleep")
    }

    @Test func approvedServiceNeedsNoExtraActivationAndRevocationIsVisible() {
        var status = SMAppService.Status.enabled
        var registrations = 0
        let controller = ClosedLidController(disabled: false,
            readServiceStatus: { status }, registerService: { registrations += 1 })
        controller.prepareSupport()
        #expect(registrations == 0)
        #expect(controller.message.hasPrefix("Ready"))
        status = .requiresApproval
        controller.update(seconds: 0, protectBattery: true, reserve: 20)
        #expect(controller.needsApproval)
    }

    @Test func registrationAwaitingApprovalIsNotShownAsSetupFailure() {
        var status = SMAppService.Status.notFound
        let controller = ClosedLidController(disabled: false,
            readServiceStatus: { status }, registerService: {
                status = .requiresApproval
                throw NSError(domain: SMAppServiceErrorDomain, code: 1)
            })
        controller.prepareSupport()
        #expect(controller.needsApproval)
        #expect(!controller.hasFailure)
        #expect(controller.message == "macOS approval required for closed-lid access")
    }

    @Test func disabledRuntimeNeverRegistersOrOpensSettings() {
        var operations = 0
        let controller = ClosedLidController(disabled: true,
            readServiceStatus: { operations += 1; return .notRegistered },
            registerService: { operations += 1 }, openSettings: { operations += 1 })
        controller.prepareSupport()
        controller.update(seconds: 0, protectBattery: true, reserve: 20)
        controller.openApprovalSettings()
        #expect(operations == 0)
    }
}
