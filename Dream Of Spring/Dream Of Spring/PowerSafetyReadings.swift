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
