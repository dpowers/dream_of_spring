//
//  main.swift
//  Dream Of Spring Lid Helper
//
import Foundation
import IOKit.pwr_mgt
import SystemConfiguration
import os

private let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "lid-helper")
private let queue = DispatchQueue(label: "art.gardenplanner.dream-of-spring.lid-helper")
private let journalDirectory = URL(fileURLWithPath: "/var/db/art.gardenplanner.Dream-Of-Spring", isDirectory: true)
private let journalURL = journalDirectory.appendingPathComponent("closed-lid-owned")

/// Only fixed pmset operations are allowed. A stalled subprocess cannot stall
/// the lease watchdog indefinitely. No commands or paths come from XPC clients.
private func pmset(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
    if process.isRunning {
        process.terminate()
        usleep(100_000)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        return nil
    }
    guard process.terminationStatus == 0,
          let data = try? pipe.fileHandleForReading.readToEnd() else { return nil }
    return String(data: data, encoding: .utf8)
}

private func readDisabled() -> Bool? {
    guard let output = pmset(["-g"]) else { return nil }
    for line in output.split(separator: "\n") {
        let parts = line.split(whereSeparator: \.isWhitespace)
        if parts.first == "SleepDisabled" {
            guard parts.count == 2, let value = Int(parts[1]), value == 0 || value == 1 else { return nil }
            return value == 1
        }
    }
    // An absent SleepDisabled setting means the normal, sleep-enabled default.
    return output.contains("System-wide power settings:") ? false : nil
}

private func journal(_ owned: Bool) -> Bool {
    do {
        if owned {
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: journalDirectory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0 else { return false }
            try Data("restore-sleep-on-restart\n".utf8).write(to: journalURL, options: .atomic)
            let file = try FileHandle(forWritingTo: journalURL)
            try file.synchronize()
            try file.close()
            let directory = open(journalDirectory.path, O_RDONLY | O_DIRECTORY)
            guard directory >= 0 else { return false }
            defer { close(directory) }
            guard fsync(directory) == 0 else { return false }
        } else if FileManager.default.fileExists(atPath: journalURL.path) {
            try FileManager.default.removeItem(at: journalURL)
        }
        return true
    } catch { return false }
}

private final class Guardian {
    let lease = ClosedLidLease(recovering: FileManager.default.fileExists(atPath: journalURL.path),
        readDisabled: readDisabled, writeDisabled: { pmset(["-a", "disablesleep", $0 ? "1" : "0"]) != nil },
        journal: journal)
    var owner: UUID?
    var allowOnBattery = false
    var protectBattery = true
    var reserve = 20.0
    var protection = BatteryProtection()
    var batteryPowerAtRenewal: Bool?

    var now: TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }

    func permitted() -> Bool {
        let battery = PowerSafetyReadings.batteryState()
        let human = PowerSafetyReadings.humanActivity()
        protection.update(battery: battery, idle: human.idle, inputCount: human.count,
            now: now, enabled: protectBattery, reserve: reserve)
        guard let battery, PowerSafetyReadings.lidIsClosed() != nil,
              battery.isOnBatteryPower == batteryPowerAtRenewal,
              ProcessInfo.processInfo.thermalState != .critical else { return false }
        return (!battery.isOnBatteryPower || allowOnBattery) && protection.plan?.remainingSeconds != 0
    }

    func update(client: UUID, seconds: Double, allowOnBattery: Bool, protectBattery: Bool, reserve: Double,
                reply: @escaping (Bool, String) -> Void) {
        guard owner == nil || owner == client else {
            reply(false, "Another Dream Of Spring instance owns closed-lid protection")
            return
        }
        if seconds <= 0 || !seconds.isFinite {
            let success = lease.release()
            if success { owner = nil }
            reply(success, lease.error)
            return
        }
        self.allowOnBattery = allowOnBattery
        self.protectBattery = protectBattery
        self.reserve = reserve.isFinite ? min(30, max(15, reserve)) : 20
        batteryPowerAtRenewal = PowerSafetyReadings.batteryState()?.isOnBatteryPower
        guard permitted() else {
            _ = lease.release()
            reply(false, "Power, battery or thermal conditions do not permit closed-lid protection")
            return
        }
        let duration = min(seconds, protection.plan?.remainingSeconds ?? .infinity)
        let success = lease.renew(seconds: duration, now: now, permitted: true)
        if success { owner = client }
        reply(success, lease.error)
    }

    func disconnect(_ client: UUID) {
        guard owner == client else { return }
        if lease.release() { owner = nil }
    }

    func tick() {
        guard lease.ownsOverride else { return }
        if !lease.expire(now: now, permitted: permitted()) {
            logger.error("Sleep recovery failed: \(self.lease.error, privacy: .public)")
        }
        if !lease.ownsOverride { owner = nil }
    }
}

private final class Client: NSObject, ClosedLidServiceProtocol {
    let id = UUID()
    let guardian: Guardian
    init(_ guardian: Guardian) { self.guardian = guardian }

    func setLease(seconds: Double, allowOnBattery: Bool, protectBattery: Bool, reserve: Double,
                  reply: @escaping (Bool, String) -> Void) {
        queue.async { [self] in
            guardian.update(client: id, seconds: seconds, allowOnBattery: allowOnBattery, protectBattery: protectBattery, reserve: reserve, reply: reply)
        }
    }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    let guardian: Guardian
    init(_ guardian: Guardian) { self.guardian = guardian }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var consoleUID: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) != nil,
              consoleUID != 0, connection.effectiveUserIdentifier == consoleUID,
              let requirement = ClosedLidService.appRequirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        let client = Client(guardian)
        connection.exportedInterface = NSXPCInterface(with: ClosedLidServiceProtocol.self)
        connection.exportedObject = client
        connection.invalidationHandler = { queue.async { client.guardian.disconnect(client.id) } }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }
}

guard geteuid() == 0 else { exit(EXIT_FAILURE) }
private let guardian = Guardian()
// Restore any journaled override before accepting new work, including after reboot.
queue.sync { _ = guardian.lease.release() }
private let delegate = Listener(guardian)
let listener = NSXPCListener(machServiceName: ClosedLidService.name)
guard let requirement = ClosedLidService.appRequirement else { exit(EXIT_FAILURE) }
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.resume()
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now(), repeating: 1)
timer.setEventHandler { guardian.tick() }
timer.resume()
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
for source in [termination, interruption] {
    source.setEventHandler {
        if guardian.lease.release() { exit(EXIT_SUCCESS) }
        // Stay alive and retry cleanup if the power service is temporarily unavailable.
        logger.error("Waiting for system sleep restoration before exiting")
    }
    source.resume()
}
dispatchMain()
