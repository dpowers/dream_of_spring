import Foundation
import Observation

@MainActor
@Observable
final class Whitelist {
    private(set) var entries: Set<AppIdentifier>

    private static let defaultsKey = "whitelistedApps"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.load(from: defaults)
    }

    func contains(_ id: AppIdentifier) -> Bool {
        entries.contains(id)
    }

    func toggle(_ id: AppIdentifier) {
        if entries.contains(id) {
            entries.remove(id)
        } else {
            entries.insert(id)
        }
        save()
    }

    func add(_ id: AppIdentifier) {
        guard !entries.contains(id) else { return }
        entries.insert(id)
        save()
    }

    func remove(_ id: AppIdentifier) {
        entries.remove(id)
        save()
    }

    private func save() {
        let sorted = Array(entries).sorted { $0.sortKey < $1.sortKey }
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> Set<AppIdentifier> {
        guard let data = defaults.data(forKey: defaultsKey),
              let array = try? JSONDecoder().decode([AppIdentifier].self, from: data) else { return [] }
        return Set(array)
    }
}

private extension AppIdentifier {
    var sortKey: String {
        switch self {
        case .bundleID(let s): return "0\t\(s)"
        case .processName(let s): return "1\t\(s)"
        }
    }
}
