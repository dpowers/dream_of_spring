//
//  EnforcementRuntimeTests.swift
//  Dream Of SpringTests
//
import Testing
@testable import Dream_Of_Spring

struct EnforcementRuntimeTests {
    @Test func normalLaunchIsEnabled() {
        #expect(!EnforcementRuntime.shouldDisable(arguments: [], environment: [:], hasXCTest: false))
    }
    @Test func explicitTestLaunchIsDisabled() {
        #expect(EnforcementRuntime.shouldDisable(arguments: ["--disable-sleep-enforcement"], environment: [:], hasXCTest: false))
    }
    @Test(arguments: ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"])
    func hostedTestsAreDisabled(key: String) {
        #expect(EnforcementRuntime.shouldDisable(arguments: [], environment: [key: "test"], hasXCTest: false))
    }
    @Test @MainActor func realActuatorIsDisabledInTests() {
        #expect(EnforcementRuntime.isDisabled)
        // Do not invoke the actuator if the guard itself regresses.
        if EnforcementRuntime.isDisabled { #expect(!SleepActuator.sleepNow()) }
    }
}
