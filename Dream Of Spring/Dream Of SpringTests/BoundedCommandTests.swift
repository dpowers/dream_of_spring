//
//  BoundedCommandTests.swift
//  Dream Of SpringTests
//
import Foundation
import Testing
@testable import Dream_Of_Spring

struct BoundedCommandTests {
    /// Regression: `pmset -a disablesleep` prints nothing, and treating that as
    /// failure made every closed-lid write and restore look like it failed.
    @Test func silentSuccessReturnsEmptyOutput() {
        #expect(BoundedCommand.run("/usr/bin/true", []) == .success(""))
    }

    @Test func returnsStandardOutput() {
        #expect(BoundedCommand.run("/bin/echo", ["SleepDisabled", "0"]) == .success("SleepDisabled 0\n"))
    }

    @Test func nonzeroExitFails() {
        #expect(BoundedCommand.run("/usr/bin/false", []) == .failure(.exit(1)))
    }

    @Test func missingExecutableFailsToLaunch() {
        guard case .failure(.launch) = BoundedCommand.run("/nonexistent/command", []) else {
            Issue.record("expected a launch failure")
            return
        }
    }

    @Test func stalledCommandTimesOut() {
        let started = ProcessInfo.processInfo.systemUptime
        #expect(BoundedCommand.run("/bin/sleep", ["10"], timeout: 0.2) == .failure(.timedOut))
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
    }
}
