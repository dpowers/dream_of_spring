//
//  EnforcementRuntime.swift
//  Dream Of Spring
//

import Foundation

nonisolated enum EnforcementRuntime {
    static var isDisabled: Bool {
        shouldDisable(arguments: ProcessInfo.processInfo.arguments,
                      environment: ProcessInfo.processInfo.environment,
                      hasXCTest: NSClassFromString("XCTestCase") != nil)
    }

    static func shouldDisable(arguments: [String], environment: [String: String], hasXCTest: Bool) -> Bool {
        arguments.contains("--disable-sleep-enforcement") || hasXCTest ||
        ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }
}
