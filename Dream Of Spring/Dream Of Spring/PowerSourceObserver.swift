//
//  PowerSourceObserver.swift
//  Dream Of Spring
//

import Foundation
import IOKit.ps
import AppKit

/// Recheck immediately when charge or the supplying power source changes.
@MainActor
final class PowerSourceObserver {
    private var source: CFRunLoopSource?
    private let onChange: @MainActor () -> Void
    private var workspaceTokens: [NSObjectProtocol] = []

    init(onChange: @MainActor @escaping () -> Void,
         onSleep: @MainActor @escaping () -> Void,
         onWake: @MainActor @escaping () -> Void) {
        self.onChange = onChange
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // This source is registered exclusively on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<PowerSourceObserver>.fromOpaque(context).takeUnretainedValue().onChange()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onWake() }
            }
        ]
    }

    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}
