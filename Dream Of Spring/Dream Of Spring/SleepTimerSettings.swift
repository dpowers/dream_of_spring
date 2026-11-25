//
//  SleepTimerSettings.swift
//  Dream Of Spring
//
import Foundation

/// Shared with the privileged helper. Only these two fixed power-source flags
/// and a bounded integer number of minutes can ever reach `pmset`.
nonisolated enum SleepTimerSource: Int, CaseIterable, Sendable {
    case battery = 0
    case ac = 1

    var pmsetFlag: String {
        switch self {
        case .battery: return "-b"
        case .ac: return "-c"
        }
    }

    /// Section headers in `pmset -g custom` output.
    var sectionHeader: String {
        switch self {
        case .battery: return "Battery Power:"
        case .ac: return "AC Power:"
        }
    }

    var label: String {
        switch self {
        case .battery: return "On battery"
        case .ac: return "On power adapter"
        }
    }
}

nonisolated struct SleepTimerSettings: Equatable, Sendable {
    struct Timers: Equatable, Sendable {
        /// `sleep` — minutes of inactivity before system sleep; 0 means Never.
        var systemMinutes: Int
        /// `displaysleep`, which System Settings does expose.
        var displayMinutes: Int?
    }

    var timers: [SleepTimerSource: Timers]

    static let maximumMinutes = 24 * 60
    /// 0 (Never) is listed last, matching the old Energy Saver slider.
    static let presetMinutes = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 0]

    static func isValid(minutes: Int) -> Bool { (0...maximumMinutes).contains(minutes) }

    static func pmsetArguments(minutes: Int, source: SleepTimerSource) -> [String]? {
        guard isValid(minutes: minutes) else { return nil }
        return [source.pmsetFlag, "sleep", String(minutes)]
    }

    /// Parses `pmset -g custom`. Desktop Macs report only an AC section; any
    /// other section (such as UPS Power) is ignored.
    static func parse(custom output: String) -> SleepTimerSettings? {
        var current: SleepTimerSource?
        var system: [SleepTimerSource: Int] = [:]
        var display: [SleepTimerSource: Int] = [:]
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let first = rawLine.first, !first.isWhitespace, line.hasSuffix(":") {
                current = SleepTimerSource.allCases.first { $0.sectionHeader == line }
                continue
            }
            guard let source = current else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let minutes = Int(parts[1]), isValid(minutes: minutes) else { continue }
            if parts[0] == "sleep" { system[source] = minutes }
            if parts[0] == "displaysleep" { display[source] = minutes }
        }
        guard !system.isEmpty else { return nil }
        var timers: [SleepTimerSource: Timers] = [:]
        for (source, minutes) in system {
            timers[source] = Timers(systemMinutes: minutes, displayMinutes: display[source])
        }
        return SleepTimerSettings(timers: timers)
    }

    static func label(minutes: Int) -> String {
        switch minutes {
        case 0: return "Never"
        case 60: return "1 hour"
        case let m where m > 60 && m % 60 == 0: return "\(m / 60) hours"
        case let m where m > 60: return "\(m / 60) hr \(m % 60) min"
        default: return "\(minutes) min"
        }
    }
}
