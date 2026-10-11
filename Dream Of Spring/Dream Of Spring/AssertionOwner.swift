//
//  AssertionOwner.swift
//  Dream Of Spring
//
import Foundation

nonisolated struct AssertionOwner: Equatable, Sendable {
    let bundleID: String
    let displayName: String
    var alternateBundleIDs: [String] = []
}

nonisolated enum AssertionOwnerResolver {
    static func resolve(
        runningApp: AssertionOwner?,
        executableURL: URL?,
        bundleAt: (URL) -> AssertionOwner?
    ) -> AssertionOwner? {
        guard let executableURL else { return runningApp }
        var url = executableURL.deletingLastPathComponent()
        var owner = runningApp
        var identifiers = runningApp.map { [$0.bundleID] } ?? []
        while url.path != "/" {
            // Only an actual application bundle establishes ownership. XPC
            // services and command-line tools inherit their containing app.
            if url.pathExtension.lowercased() == "app", let app = bundleAt(url) {
                owner = app
                identifiers.append(app.bundleID)
            }
            let parent = url.deletingLastPathComponent()
            guard parent != url else { break }
            url = parent
        }
        guard var owner else { return nil }
        owner.alternateBundleIDs = Array(Set(identifiers).subtracting([owner.bundleID])).sorted()
        return owner
    }
}
