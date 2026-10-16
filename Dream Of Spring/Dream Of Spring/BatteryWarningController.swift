//
//  BatteryWarningController.swift
//  Dream Of Spring
//

import AppKit
import SwiftUI

/// A nonactivating panel stays visible over full-screen video without taking
/// keyboard focus. Only observed input, not presenting the warning, renews time.
@MainActor
final class BatteryWarningController {
    private var panel: NSPanel?
    private let state = BatteryWarningState()

    func update(plan: BatteryPlan?, battery: BatteryState?, reserve: Double) {
        guard let plan, plan.shouldWarn, let battery else { hide(); return }
        state.seconds = max(1, Int(ceil(plan.remainingSeconds)))
        state.percentage = Int(battery.percentage.rounded())
        state.reserve = Int(reserve)
        if panel == nil {
            let window = BatteryWarningPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 210),
                                 styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Battery reserve protection"
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.isFloatingPanel = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: BatteryWarningView(state: state))
            panel = window
        }
        guard let panel, !panel.isVisible else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 24))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

private final class BatteryWarningPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
private final class BatteryWarningState {
    var seconds = 60
    var percentage = 20
    var reserve = 20
}

private struct BatteryWarningView: View {
    let state: BatteryWarningState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sleeping in \(state.seconds) seconds", systemImage: "battery.25percent")
                .font(.title3.bold()).monospacedDigit()
                .accessibilityIdentifier("batterySleepCountdown")
            Text("Battery is at \(state.percentage)%. Dream Of Spring will sleep your Mac to preserve your remaining charge.")
            Text("Move the pointer or press a key to stay awake.")
                .fontWeight(.semibold)
            Text("Reserve target: \(state.reserve)% · Plug in to continue unattended.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 370, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
