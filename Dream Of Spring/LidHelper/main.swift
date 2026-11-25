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
    switch BoundedCommand.run("/usr/bin/pmset", arguments) {
    case .success(let output):
        return output
    case .failure(let failure):
        logger.error("pmset \(arguments.joined(separator: " "), privacy: .public) \(failure.description, privacy: .public)")
        return nil
    }
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

/// The running binary's path, captured at launch while it still exists on disk.
private func executablePath() -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
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
    let path: String?
    var updates: HelperUpdateMonitor?

    init() {
        path = executablePath()
        updates = path.flatMap(ExecutableIdentity.read).map(HelperUpdateMonitor.init)
    }

    var now: TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }

    func permitted() -> Bool {
        let battery = PowerSafetyReadings.batteryState()
        let events = PowerSafetyReadings.humanActivity()
        let human = PowerSafetyReadings.daemonActivity(count: events.count, eventIdle: events.idle,
            registryIdle: PowerSafetyReadings.hidIdleSeconds())
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
        restartIfUpdated()
        guard lease.ownsOverride else { return }
        if !lease.expire(now: now, permitted: permitted()) {
            logger.error("Sleep recovery failed: \(self.lease.error, privacy: .public)")
        }
        if !lease.ownsOverride { owner = nil }
    }

    /// Installing a new app replaces this file, but launchd keeps the old
    /// process alive. Exit so KeepAlive starts the update. A failed restore
    /// leaves the journal in place, so the new helper's startup recovery
    /// retries it; waiting here could strand an old helper indefinitely.
    private func restartIfUpdated() {
        guard let path, updates?.observe(ExecutableIdentity.read(path: path)) == true else { return }
        if !lease.release() {
            logger.error("Exiting for helper update before sleep was restored; the new helper will recover: \(self.lease.error, privacy: .public)")
        }
        logger.notice("Helper executable was updated; exiting so launchd starts the new version")
        exit(EXIT_SUCCESS)
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

    func setSleepTimer(minutes: Int, source: Int, reply: @escaping (Bool, String) -> Void) {
        queue.async {
            guard let source = SleepTimerSource(rawValue: source),
                  let arguments = SleepTimerSettings.pmsetArguments(minutes: minutes, source: source) else {
                reply(false, "Invalid sleep timer request")
                return
            }
            guard pmset(arguments) != nil else {
                reply(false, "macOS rejected the sleep timer change")
                return
            }
            guard let output = pmset(["-g", "custom"]),
                  SleepTimerSettings.parse(custom: output)?.timers[source]?.systemMinutes == minutes else {
                reply(false, "macOS did not apply the sleep timer change")
                return
            }
            logger.notice("Set \(source.label, privacy: .public) sleep timer to \(minutes, privacy: .public) min")
            reply(true, "")
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
