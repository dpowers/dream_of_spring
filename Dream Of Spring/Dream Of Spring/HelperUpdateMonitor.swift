//
//  HelperUpdateMonitor.swift
//  Dream Of Spring
//
import Foundation

/// Identity of a file on disk. Replacing the app bundle gives the helper's
/// executable a new inode, even when the running process keeps the old one open.
nonisolated struct ExecutableIdentity: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int

    static func read(path: String) -> ExecutableIdentity? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return ExecutableIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            size: Int64(info.st_size), modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }
}

/// Decides when the root helper should exit so launchd relaunches the updated
/// binary. Installs delete and then copy the bundle, so a missing or still
/// changing file is ignored until the replacement stays stable for a few polls.
nonisolated struct HelperUpdateMonitor: Sendable {
    static let requiredStableObservations = 3

    let original: ExecutableIdentity
    private var candidate: ExecutableIdentity?
    private var stableObservations = 0

    init(original: ExecutableIdentity) { self.original = original }

    /// Returns true once a different executable has been stable long enough.
    mutating func observe(_ current: ExecutableIdentity?) -> Bool {
        guard let current, current != original else {
            candidate = nil
            stableObservations = 0
            return false
        }
        if current == candidate {
            stableObservations += 1
        } else {
            candidate = current
            stableObservations = 1
        }
        return stableObservations >= Self.requiredStableObservations
    }
}
