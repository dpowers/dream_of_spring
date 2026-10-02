import Foundation
import IOKit
import IOKit.pwr_mgt
import os

enum SleepActuator {
    private static let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "actuator")

    /// Asks the system to sleep now. Equivalent to `pmset sleepnow`. Overrides
    /// `PreventUserIdleSystemSleep` assertions because this is a user-initiated
    /// sleep request, not an idle-driven one. Returns true on success so the
    /// enforcer can surface a persistent failure in the menu rather than
    /// silently looping every cooldown interval.
    static func sleepNow() -> Bool {
        guard !EnforcementRuntime.isDisabled else { return false }
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != 0 else {
            logger.error("IOPMFindPowerManagement returned 0 — no root power management port")
            return false
        }
        defer { IOServiceClose(port) }
        let kr = IOPMSleepSystem(port)
        if kr == kIOReturnSuccess {
            logger.info("IOPMSleepSystem succeeded")
            return true
        }
        logger.error("IOPMSleepSystem failed: kr=\(String(format: "0x%08x", kr), privacy: .public)")
        return false
    }
}
