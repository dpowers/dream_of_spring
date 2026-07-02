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

    /// True when any camera (CoreMediaIO device) is running in any process —
    /// the same signal that drives the system's green camera indicator.
    static func cameraInUse() -> Bool {
        var listAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &listAddress, 0, nil, &dataSize) == kCMIOHardwareNoError else {
            logger.error("CMIO device list size read failed")
            return false
        }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &listAddress, 0, nil, dataSize, &dataUsed, &devices) == kCMIOHardwareNoError else {
            logger.error("CMIO device list read failed")
            return false
        }
        var runningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
        )
        for device in devices {
            var isRunning: UInt32 = 0
            var used: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &isRunning) == kCMIOHardwareNoError,
               isRunning != 0 {
                return true
            }
        }
        return false
    }

    /// True when any process has an active *input* audio stream — i.e. is
    /// actually capturing microphone audio. Uses the per-process CoreAudio
    /// objects rather than `kAudioDevicePropertyDeviceIsRunningSomewhere`,
    /// which would false-positive on combo input/output devices (AirPods,
    /// USB headsets) whenever they merely play sound.
    static func microphoneInUse() -> Bool {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &dataSize) == noErr else {
            logger.error("CoreAudio process list size read failed")
            return false
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &dataSize, &processes) == noErr else {
            logger.error("CoreAudio process list read failed")
            return false
        }
        var runningInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for process in processes {
            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(process, &runningInputAddress, 0, nil, &size, &isRunning) == noErr,
               isRunning != 0 {
                return true
            }
        }
        return false
    }
}
