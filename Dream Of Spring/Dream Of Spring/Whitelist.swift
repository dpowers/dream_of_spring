import Foundation
import Observation
import os

nonisolated enum WhitelistPolicy: Hashable, Codable, Sendable {
    /// Veto forced sleep while this app holds a sleep-prevention assertion.
    case alwaysAllow
    /// Treat the app as exempt while user idle is less than this absolute
    /// number of seconds; once idle reaches it, force sleep as usual. Useful
    /// for video sites that legitimately keep the Mac awake but where you
    /// still want sleep to win after a long unattended stretch.
    case allowUpTo(seconds: TimeInterval)

    /// The idle-time threshold at which this policy stops exempting the app.
    /// `nil` policy (no entry) is handled by the caller and equals `timeout`.
    func effectiveThreshold(configuredTimeout: TimeInterval) -> TimeInterval {
        switch self {
        case .alwaysAllow: return .infinity
        case .allowUpTo(let s): return max(configuredTimeout, s)
        }
    }
}

/// User-facing presets for `.allowUpTo`. Order is preserved for the menu.
nonisolated enum WhitelistPreset {
    static let allowUpToOptions: [(label: String, seconds: TimeInterval)] = [
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour", 60 * 60),
        ("2 hours", 120 * 60)
    ]
}

/// Persisted shape — array on disk because Dictionary keys with associated
/// values don't round-trip through `JSONEncoder` cleanly.
nonisolated struct WhitelistEntry: Hashable, Codable, Sendable {
    let id: AppIdentifier
    let policy: WhitelistPolicy
}

@MainActor
@Observable
final class Whitelist {
    private static let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "whitelist")

    private(set) var policies: [AppIdentifier: WhitelistPolicy] = [:]

    private static let policiesKey = "whitelistPolicies"
    private static let legacyKey = "whitelistedApps"   // pre-policy: [AppIdentifier]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func contains(_ id: AppIdentifier) -> Bool { policies[id] != nil }

    func policy(for id: AppIdentifier) -> WhitelistPolicy? { policies[id] }

    /// Idle-time threshold past which an app with this identifier's policy
    /// stops being exempt and counts as an active blocker. `nil` (no entry)
    /// returns `configuredTimeout`; `.alwaysAllow` returns `.infinity`.
    func effectiveThreshold(for id: AppIdentifier, configuredTimeout: TimeInterval) -> TimeInterval {
        guard let p = policies[id] else { return configuredTimeout }
        return p.effectiveThreshold(configuredTimeout: configuredTimeout)
    }

    /// System sleep affects every app, so the longest active exemption wins.
    /// Infinity means an active app must be allowed to keep the Mac awake.
    func sleepDeadline(for identifiers: [AppIdentifier], configuredTimeout: TimeInterval) -> TimeInterval? {
        identifiers.map {
            effectiveThreshold(for: $0, configuredTimeout: configuredTimeout) + Decider.graceSeconds
        }.max()
    }

    func setPolicy(_ policy: WhitelistPolicy, for id: AppIdentifier) {
        policies[id] = policy
        save()
    }

    func remove(_ id: AppIdentifier) {
        policies.removeValue(forKey: id)
        save()
    }

    private func save() {
        let entries = policies
            .map { WhitelistEntry(id: $0.key, policy: $0.value) }
            .sorted { $0.id.sortKey < $1.id.sortKey }
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: Self.policiesKey)
        } catch {
            Self.logger.error("Failed to encode whitelist (\(entries.count, privacy: .public) entries): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        if let data = defaults.data(forKey: Self.policiesKey) {
            do {
                let entries = try JSONDecoder().decode([WhitelistEntry].self, from: data)
                policies = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.policy) })
                return
            } catch {
                Self.logger.error("Failed to decode whitelist: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Migrate from the pre-policy `Set<AppIdentifier>` shape: every old
        // entry becomes `.alwaysAllow`, matching its prior behavior.
        guard let data = defaults.data(forKey: Self.legacyKey) else { return }
        do {
            let legacy = try JSONDecoder().decode([AppIdentifier].self, from: data)
            policies = Dictionary(uniqueKeysWithValues: legacy.map { ($0, .alwaysAllow) })
            save()
            defaults.removeObject(forKey: Self.legacyKey)
            Self.logger.info("Migrated \(legacy.count, privacy: .public) entries from legacy whitelist format")
        } catch {
            Self.logger.error("Failed to decode legacy whitelist: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension AppIdentifier {
    var sortKey: String {
        switch self {
        case .bundleID(let s): return "0\t\(s)"
        case .processName(let s): return "1\t\(s)"
        }
    }
}
