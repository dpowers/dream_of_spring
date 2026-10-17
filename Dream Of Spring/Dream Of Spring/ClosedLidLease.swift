//
//  ClosedLidLease.swift
//  Dream Of Spring
//
import Foundation

/// Serialized by the helper's queue; all side effects are injected for tests.
/// The journal is written BEFORE changing the system, and removed only AFTER
/// restoring it. A restarted helper can therefore recover a half-finished change.
nonisolated final class ClosedLidLease {
    private(set) var ownsOverride: Bool
    private(set) var expiresAt: TimeInterval = 0
    private(set) var error = ""
    private let readDisabled: () -> Bool?
    private let writeDisabled: (Bool) -> Bool
    private let journal: (Bool) -> Bool

    init(recovering: Bool, readDisabled: @escaping () -> Bool?,
         writeDisabled: @escaping (Bool) -> Bool, journal: @escaping (Bool) -> Bool) {
        ownsOverride = recovering
        self.readDisabled = readDisabled
        self.writeDisabled = writeDisabled
        self.journal = journal
    }

    @discardableResult
    func renew(seconds: TimeInterval, now: TimeInterval, permitted: Bool) -> Bool {
        guard permitted, seconds.isFinite, seconds > 0, now.isFinite else { return release() }
        guard let disabled = readDisabled() else {
            _ = release()
            error = "Cannot read the system sleep setting"
            return false
        }
        if !ownsOverride {
            guard !disabled else {
                error = "Another utility has disabled system sleep"
                return false
            }
            guard journal(true) else {
                error = "Cannot save sleep recovery information"
                return false
            }
            ownsOverride = true
            guard writeDisabled(true), readDisabled() == true else {
                _ = release()
                error = "macOS did not enable closed-lid protection"
                return false
            }
        } else if !disabled {
            _ = release()
            error = "The system sleep setting changed outside Dream Of Spring"
            return false
        }
        expiresAt = now + min(seconds, ClosedLidService.maximumLeaseSeconds)
        error = ""
        return true
    }

    @discardableResult
    func expire(now: TimeInterval, permitted: Bool) -> Bool {
        guard ownsOverride, !permitted || !now.isFinite || now >= expiresAt else { return true }
        return release()
    }

    @discardableResult
    func release() -> Bool {
        expiresAt = 0
        guard ownsOverride else { return true }
        // Do not discard ownership on failure: the watchdog must keep retrying.
        guard writeDisabled(false), readDisabled() == false else {
            error = "Could not restore system sleep; recovery will retry"
            return false
        }
        guard journal(false) else {
            error = "Could not clear sleep recovery information"
            return false
        }
        ownsOverride = false
        error = ""
        return true
    }
}
