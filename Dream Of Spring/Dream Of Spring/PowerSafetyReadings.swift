//
//  PowerSafetyReadings.swift
//  Dream Of Spring
//
import Foundation
import IOKit
import IOKit.ps
import CoreGraphics

/// Also compiled into the helper so a stalled GUI cannot bypass battery protection.
nonisolated enum PowerSafetyReadings {
    static func lidIsClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    static func humanActivity() -> (count: UInt64, idle: TimeInterval) {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel, .tabletPointer, .tabletProximity]
        let count = types.reduce(UInt64(0)) {
            $0 + UInt64(CGEventSource.counterForEventType(.hidSystemState, eventType: $1))
        }
        let idle = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
        return (count, idle)
    }

    /// `HIDIdleTime` from the registry; readable without a window-server session.
    static func hidIdleSeconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let nanoseconds = (prop as? NSNumber)?.int64Value else { return nil }
        return TimeInterval(nanoseconds) / 1_000_000_000
    }

    /// The root helper has no GUI session, where the event-state table may
    /// not be readable. An all-zero count means no counter at all, so fall
    /// back to the registry idle time rather than a last-input time that can
    /// never advance.
    static func daemonActivity(count: UInt64, eventIdle: TimeInterval,
                               registryIdle: TimeInterval?) -> (count: UInt64?, idle: TimeInterval) {
        count == 0 ? (nil, registryIdle ?? eventIdle) : (count, eventIdle)
    }

    static func batteryState() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery",
                  description["Is Present"] as? Bool == true,
                  let current = description["Current Capacity"] as? NSNumber,
                  let maximum = description["Max Capacity"] as? NSNumber else { continue }
            return BatteryState.validated(currentCapacity: current.doubleValue,
                maxCapacity: maximum.doubleValue, isOnBatteryPower: providing as String == "Battery Power")
        }
        return nil
    }
}
