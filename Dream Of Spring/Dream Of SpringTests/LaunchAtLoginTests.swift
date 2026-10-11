//
//  LaunchAtLoginTests.swift
//  Dream Of SpringTests
//

import Foundation
import ServiceManagement
import Testing
@testable import Dream_Of_Spring

@MainActor
struct LaunchAtLoginTests {
    @MainActor
    private final class Service {
        var status: SMAppService.Status = .notRegistered
        var registrationRequiresApproval = false
        var registrations = 0
        var unregistrations = 0
        var settingsOpens = 0

        func controller() -> LaunchAtLogin {
            LaunchAtLogin(startAutomatically: false, readStatus: { self.status }, register: {
                self.registrations += 1
                if self.registrationRequiresApproval {
                    self.status = .requiresApproval
                    throw NSError(domain: "LaunchAtLoginTests", code: 1)
                }
                self.status = .enabled
            }, unregister: {
                self.unregistrations += 1
                self.status = .notRegistered
            }, openSettings: { self.settingsOpens += 1 })
        }
    }

    @Test func deniedLoginItemOpensSettingsInsteadOfRegisteringAgain() {
        let service = Service()
        service.status = .requiresApproval
        let controller = service.controller()

        controller.toggle()

        #expect(service.settingsOpens == 1)
        #expect(service.registrations == 0)
        #expect(service.unregistrations == 0)
        #expect(!controller.isEnabled)
    }

    @Test func approvalRequiredDuringRegistrationOpensSettings() {
        let service = Service()
        service.registrationRequiresApproval = true
        let controller = service.controller()

        controller.toggle()

        #expect(service.registrations == 1)
        #expect(service.settingsOpens == 1)
        #expect(!controller.isEnabled)

        service.status = .enabled
        controller.refresh()
        #expect(controller.isEnabled)
    }

    @Test func toggleReadsApprovalStatusChangedSinceLastRefresh() {
        let service = Service()
        service.status = .enabled
        let controller = service.controller()
        service.status = .requiresApproval

        controller.toggle()

        #expect(service.settingsOpens == 1)
        #expect(service.registrations == 0)
        #expect(service.unregistrations == 0)
        #expect(!controller.isEnabled)
    }

    @Test func ordinaryToggleRegistersAndUnregisters() {
        let service = Service()
        let controller = service.controller()

        controller.toggle()
        #expect(controller.isEnabled)
        #expect(service.registrations == 1)

        controller.toggle()
        #expect(!controller.isEnabled)
        #expect(service.unregistrations == 1)
        #expect(service.settingsOpens == 0)
    }
}
