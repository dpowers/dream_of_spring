import Foundation
import CoreAudio
import CoreMediaIO
import os

/// Reads whether any process on the system is actively capturing from a
/// camera or microphone. A live call or recording would be killed by a forced
/// sleep, and call apps (FaceTime, Meet, Zoom) hold their keep-awake
/// assertions via daemons (`avconferenced`, `coreaudiod`) that never appear
/// in the blocker list — so the enforcer treats active capture as a global
/// veto rather than something the whitelist could express.
///
/// Neither read opens a capture stream, so neither triggers a TCC
/// (camera/microphone permission) prompt — they only inspect device and
/// process state.
enum CaptureActivity {
    private static let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "capture")

    /// Active when any camera (CoreMediaIO device) is running in any process —
    /// the same signal that drives the system's green camera indicator.
    static func cameraInUse() -> ActivityState {
        var listAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &listAddress, 0, nil, &dataSize) == kCMIOHardwareNoError else {
            logger.error("CMIO device list size read failed")
            return .unknown
        }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return .inactive }
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &listAddress, 0, nil, dataSize, &dataUsed, &devices) == kCMIOHardwareNoError else {
            logger.error("CMIO device list read failed")
            return .unknown
        }
        var runningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard dataUsed <= dataSize, Int(dataUsed) % MemoryLayout<CMIOObjectID>.size == 0 else { return .unknown }
        var states: [ActivityState] = []
        for device in devices.prefix(Int(dataUsed) / MemoryLayout<CMIOObjectID>.size) {
            var isRunning: UInt32 = 0
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &runningAddress, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &used, &isRunning)
            let state = ActivityState.sample(status: status, value: isRunning, bytes: used)
            if state == .unknown { logger.error("CMIO running-state read failed: \(status)") }
            states.append(state)
        }
        return .combined(states)
    }

    /// Active when any process has an active *input* audio stream — i.e. is
    /// actually capturing microphone audio. Uses the per-process CoreAudio
    /// objects rather than `kAudioDevicePropertyDeviceIsRunningSomewhere`,
    /// which would false-positive on combo input/output devices (AirPods,
    /// USB headsets) whenever they merely play sound.
    static func microphoneInUse() -> ActivityState {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &dataSize) == noErr else {
            logger.error("CoreAudio process list size read failed")
            return .unknown
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return .inactive }
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &dataSize, &processes) == noErr else {
            logger.error("CoreAudio process list read failed")
            return .unknown
        }
        var runningInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard Int(dataSize) <= processes.count * MemoryLayout<AudioObjectID>.size,
              Int(dataSize) % MemoryLayout<AudioObjectID>.size == 0 else { return .unknown }
        var states: [ActivityState] = []
        for process in processes.prefix(Int(dataSize) / MemoryLayout<AudioObjectID>.size) {
            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(process, &runningInputAddress, 0, nil, &size, &isRunning)
            let state = ActivityState.sample(status: status, value: isRunning, bytes: size)
            if state == .unknown { logger.error("CoreAudio input-state read failed: \(status)") }
            states.append(state)
        }
        return .combined(states)
    }
}
