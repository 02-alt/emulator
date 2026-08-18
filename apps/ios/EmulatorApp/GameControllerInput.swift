import Foundation
import Observation
import GameController
import EmulatorCore

/// Bridges MFi / Xbox / DualSense controllers to GBA buttons. Reports the held mask via `onChange`
/// and a menu request (Home button, or L3+R3 as a universal fallback) via `onMenu`. Mirrors the
/// macOS `GameControllerManager` mapping, trimmed to what the iOS play screen needs.
@Observable
final class GameControllerInput {
    /// Held GBA buttons from the controller (unioned with touch input by the caller).
    @ObservationIgnored var onChange: ((GBAButtons) -> Void)?
    /// Home / L3+R3 pressed — open or close the in-game menu.
    @ObservationIgnored var onMenu: (() -> Void)?

    /// Whether a controller is currently attached — the play screen hides the on-screen pad when so.
    private(set) var isConnected = false

    /// Left-stick travel (0…1) required before it stands in for the D-pad.
    private static let stickDeadzone: Float = 0.5

    @ObservationIgnored private var attached: [GCController] = []
    @ObservationIgnored private var prevHome = false
    @ObservationIgnored private var prevCombo = false

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(connected(_:)), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(disconnected(_:)), name: .GCControllerDidDisconnect, object: nil)
        for controller in GCController.controllers() { attach(controller) }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for controller in attached { controller.extendedGamepad?.valueChangedHandler = nil }
    }

    @objc private func connected(_ note: Notification) {
        if let controller = note.object as? GCController { attach(controller) }
    }

    @objc private func disconnected(_ note: Notification) {
        if let controller = note.object as? GCController {
            controller.extendedGamepad?.valueChangedHandler = nil
            attached.removeAll { $0 === controller }
        }
        isConnected = !attached.isEmpty
        onChange?([])   // release everything if the pad went away mid-press
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        controller.handlerQueue = .main
        if !attached.contains(where: { $0 === controller }) { attached.append(controller) }
        isConnected = true

        pad.valueChangedHandler = { [weak self] gamepad, _ in
            guard let self else { return }

            let home = gamepad.buttonHome?.isPressed ?? false
            let l3 = gamepad.leftThumbstickButton?.isPressed ?? false
            let r3 = gamepad.rightThumbstickButton?.isPressed ?? false
            let combo = l3 && r3
            if (home && !self.prevHome) || (combo && !self.prevCombo) { self.onMenu?() }
            self.prevHome = home; self.prevCombo = combo

            var b: GBAButtons = []
            if gamepad.buttonA.isPressed { b.insert(.a) }        // cross / A
            if gamepad.buttonB.isPressed { b.insert(.b) }        // circle / B
            if gamepad.leftShoulder.isPressed { b.insert(.l) }
            if gamepad.rightShoulder.isPressed { b.insert(.r) }
            if gamepad.dpad.up.isPressed { b.insert(.up) }
            if gamepad.dpad.down.isPressed { b.insert(.down) }
            if gamepad.dpad.left.isPressed { b.insert(.left) }
            if gamepad.dpad.right.isPressed { b.insert(.right) }
            if AppSettings.joystickAsDpad {
                let sx = gamepad.leftThumbstick.xAxis.value, sy = gamepad.leftThumbstick.yAxis.value
                let dz = Self.stickDeadzone
                if sy > dz { b.insert(.up) }
                if sy < -dz { b.insert(.down) }
                if sx < -dz { b.insert(.left) }
                if sx > dz { b.insert(.right) }
            }
            if gamepad.buttonMenu.isPressed { b.insert(.start) }
            if gamepad.buttonOptions?.isPressed ?? false { b.insert(.select) }

            self.onChange?(b)
        }
    }
}
