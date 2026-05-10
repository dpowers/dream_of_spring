import Foundation
import Observation

nonisolated enum WhitelistPolicy: Hashable, Codable, Sendable {
    /// Never force sleep on account of this app.
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

    /// Add (with `.alwaysAllow`) if absent, remove if present. Used by the
    /// inline blocker toggle for the binary "is this whitelisted at all" case.
    func toggle(_ id: AppIdentifier) {
        if policies[id] == nil {
            policies[id] = .alwaysAllow
        } else {
            policies.removeValue(forKey: id)
        }
        save()
    }

    func add(_ id: AppIdentifier, policy: WhitelistPolicy = .alwaysAllow) {
        guard policies[id] != policy else { return }
        policies[id] = policy
        save()
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
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.policiesKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: Self.policiesKey),
           let entries = try? JSONDecoder().decode([WhitelistEntry].self, from: data) {
            policies = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.policy) })
            return
        }
        // Migrate from the pre-policy `Set<AppIdentifier>` shape: every old
        // entry becomes `.alwaysAllow`, matching its prior behavior.
        if let data = defaults.data(forKey: Self.legacyKey),
           let legacy = try? JSONDecoder().decode([AppIdentifier].self, from: data) {
            policies = Dictionary(uniqueKeysWithValues: legacy.map { ($0, .alwaysAllow) })
            save()
            defaults.removeObject(forKey: Self.legacyKey)
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
