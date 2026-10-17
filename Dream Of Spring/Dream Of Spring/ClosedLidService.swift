//
//  ClosedLidService.swift
//  Dream Of Spring
//
import Foundation
import Security

/// Shared with the separately compiled privileged helper. No arbitrary commands,
/// file paths or executable arguments cross this interface.
@objc protocol ClosedLidServiceProtocol {
    func setLease(seconds: Double, allowOnBattery: Bool, protectBattery: Bool, reserve: Double,
                  reply: @escaping (Bool, String) -> Void)
}

nonisolated enum ClosedLidService {
    static let name = "art.gardenplanner.Dream-Of-Spring.LidHelper"
    static let plistName = name + ".plist"
    static let maximumLeaseSeconds: TimeInterval = 10
    static let pollSeconds: TimeInterval = 2
    static var appRequirement: String? { requirement(identifier: "art.gardenplanner.Dream-Of-Spring") }
    static var helperRequirement: String? { requirement(identifier: name) }

    private static func requirement(identifier: String) -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
