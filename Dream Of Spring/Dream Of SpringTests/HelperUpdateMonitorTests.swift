//
//  HelperUpdateMonitorTests.swift
//  Dream Of SpringTests
//
import Foundation
import Testing
@testable import Dream_Of_Spring

struct HelperUpdateMonitorTests {
    private func identity(inode: UInt64, size: Int64 = 100, modified: Int = 1) -> ExecutableIdentity {
        ExecutableIdentity(device: 1, inode: inode, size: size, modifiedSeconds: modified, modifiedNanoseconds: 0)
    }

    /// Feeds each observation to a fresh monitor and returns its decisions.
    private func decisions(_ observations: [ExecutableIdentity?]) -> [Bool] {
        var monitor = HelperUpdateMonitor(original: identity(inode: 1))
        return observations.map { monitor.observe($0) }
    }

    @Test func unchangedExecutableNeverRestarts() {
        #expect(decisions(Array(repeating: identity(inode: 1), count: 10)) == Array(repeating: false, count: 10))
    }

    @Test func missingExecutableDuringInstallDoesNotRestart() {
        #expect(decisions(Array(repeating: nil, count: 10)) == Array(repeating: false, count: 10))
    }

    @Test func replacedExecutableRestartsOnceStable() {
        let replacement = identity(inode: 2)
        #expect(decisions([replacement, replacement, replacement]) == [false, false, true])
    }

    @Test func executableStillBeingCopiedWaitsUntilStable() {
        let sizes: [Int64] = [10, 50, 100, 100, 100]
        #expect(decisions(sizes.map { identity(inode: 2, size: $0) }) == [false, false, false, false, true])
    }

    @Test func disappearanceResetsStability() {
        let replacement = identity(inode: 2)
        #expect(decisions([replacement, replacement, nil, replacement, replacement, replacement])
            == [false, false, false, false, false, true])
    }

    @Test func returningToOriginalResetsStability() {
        let original = identity(inode: 1), replacement = identity(inode: 2)
        #expect(decisions([replacement, replacement, original, replacement, replacement])
            == [false, false, false, false, false])
    }

    @Test func readsRealFileIdentityAndDetectsReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("helper")
        try Data("old".utf8).write(to: file)
        let original = try #require(ExecutableIdentity.read(path: file.path))
        #expect(ExecutableIdentity.read(path: directory.path) == nil)

        // Mirror install.sh: delete, then copy in a new file.
        try FileManager.default.removeItem(at: file)
        #expect(ExecutableIdentity.read(path: file.path) == nil)
        try Data("new".utf8).write(to: file)
        let replacement = try #require(ExecutableIdentity.read(path: file.path))
        #expect(replacement != original)
    }
}
