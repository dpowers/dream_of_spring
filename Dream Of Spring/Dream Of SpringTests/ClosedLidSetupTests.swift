//
//  ClosedLidSetupTests.swift
//  Dream Of SpringTests
//
import ServiceManagement
import Testing
@testable import Dream_Of_Spring

@MainActor
struct ClosedLidSetupTests {
    @Test func startupRegistersWithoutOpeningSettingsAndPicksUpApprovalWhileIdle() {
        var status = SMAppService.Status.notRegistered
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
