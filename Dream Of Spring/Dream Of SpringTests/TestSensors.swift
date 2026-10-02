//
//  TestSensors.swift
//  Dream Of SpringTests
//
import Foundation
@testable import Dream_Of_Spring

/// Mutable sensor state stays on the same actor as the injected closures.
@MainActor final class TestSensors {
    var inputs: EnforcerReadings
    var uptime: TimeInterval = 0
    var sleepCalls = 0

    init(_ inputs: EnforcerReadings) { self.inputs = inputs }
}
