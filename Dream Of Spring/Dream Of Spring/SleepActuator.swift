import Foundation
import IOKit
import IOKit.pwr_mgt
import os

enum SleepActuator {
    private static let logger = Logger(subsystem: "art.gardenplanner.dream-of-spring", category: "actuator")

    /// Asks the system to sleep now. Equivalent to `pmset sleepnow`. Overrides
    /// `PreventUserIdleSystemSleep` assertions because this is a user-initiated
    /// sleep request, not an idle-driven one.
    static func sleepNow() {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != 0 else {
            logger.error("IOPMFindPowerManagement returned 0 — no root power management port")
            return
        }
        defer { IOServiceClose(port) }
        let kr = IOPMSleepSystem(port)
        if kr == kIOReturnSuccess {
            logger.info("IOPMSleepSystem succeeded")
        } else {
            logger.error("IOPMSleepSystem failed: kr=\(String(format: "0x%08x", kr), privacy: .public)")
        }
    }
}
