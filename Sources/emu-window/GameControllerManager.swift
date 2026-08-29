import EmulatorCore
import Foundation
import GameController

/// Bridges MFi/Xbox/DualSense controllers to GBA buttons and pushes them into the driver.
/// Handlers are pinned to the main queue; updates go through the driver's thread-safe `setPad`.
final class GameControllerManager: @unchecked Sendable {
    private let driver: EmulationDriver
    private var attached: [GCController] = []

    /// How far the analog stick must travel (0…1) before it counts as a D-pad press. Keeps a
    /// resting/drifting stick from firing directions.
    private static let stickDeadzone: Float = 0.5

    /// Convert a GameController axis (−1…1, +Y = up) to the pad's Int16 range (−32768…32767),
    /// keeping the +Y-is-up convention `PadInput` uses.
    private static func axis(_ v: Float) -> Int16 { Int16(clamping: Int((v * 32767).rounded())) }

    /// Cached ``Settings/joystickAsDpad`` so the (non-actor-isolated) value handler can read it
    /// without hopping to the main actor. Refreshed on ``Settings/didChange``.
    private var joystickAsDpad = true

    // MARK: Controller guide (console-style Home-button dashboard)

    /// Whether the guide overlay is currently open — set by the play view, checked each input to
    /// decide between driving the game and navigating the menu.
    var isGuideOpen: (@MainActor () -> Bool)?
    /// Home button (or L3+R3) pressed — open/close the guide.
    var onGuideToggle: (@MainActor () -> Void)?
    /// D-pad up/down while the guide is open — step the focus (true = down/next).
    var onGuideMove: (@MainActor (Bool) -> Void)?
    /// D-pad left/right while the guide is open — adjust the focused control, e.g. the ambience
    /// volume (true = right/increase). On the horizontal toolbar it also steps the focus.
    var onGuideAdjust: (@MainActor (Bool) -> Void)?
    /// A while the guide is open — activate the focused button.
    var onGuideActivate: (@MainActor () -> Void)?
    /// B while the guide is open — close the guide.
    var onGuideClose: (@MainActor () -> Void)?

    // Previous pressed states for edge detection (touched only on the main queue).
    private var prevHome = false, prevCombo = false, prevA = false, prevB = false
    private var prevUp = false, prevDown = false, prevLeft = false, prevRight = false

    init(driver: EmulationDriver) {
        self.driver = driver
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerConnected(_:)),
            name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil)
        MainActor.assumeIsolated { joystickAsDpad = Settings.shared.joystickAsDpad }
        for controller in GCController.controllers() { attach(controller) }
    }

    /// GCControllers are system-shared and outlive this manager, so we must remove our observer and
    /// clear the handlers we installed — otherwise a handler capturing our (freed) driver stays live
    /// on the controller and fires into freed memory.
    deinit {
        NotificationCenter.default.removeObserver(self)
        for controller in attached { controller.extendedGamepad?.valueChangedHandler = nil }
    }

    @objc private func controllerConnected(_ note: Notification) {
        if let controller = note.object as? GCController { attach(controller) }
    }

    @objc private func settingsChanged() {
        MainActor.assumeIsolated { joystickAsDpad = Settings.shared.joystickAsDpad }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        controller.handlerQueue = .main
        attached.append(controller)
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            guard let self else { return }
            // Read everything as Sendable primitives before hopping to the main actor — the gamepad
            // itself isn't Sendable, so it must not cross the isolation boundary.
            let home = gamepad.buttonHome?.isPressed ?? false
            let l3 = gamepad.leftThumbstickButton?.isPressed ?? false
            let r3 = gamepad.rightThumbstickButton?.isPressed ?? false
            let up = gamepad.dpad.up.isPressed, down = gamepad.dpad.down.isPressed
            let left = gamepad.dpad.left.isPressed, right = gamepad.dpad.right.isPressed
            let a = gamepad.buttonA.isPressed, bb = gamepad.buttonB.isPressed
            let bx = gamepad.buttonX.isPressed, by = gamepad.buttonY.isPressed
            let lsh = gamepad.leftShoulder.isPressed, rsh = gamepad.rightShoulder.isPressed
            let lt = gamepad.leftTrigger.isPressed, rt = gamepad.rightTrigger.isPressed
            let sx = gamepad.leftThumbstick.xAxis.value, sy = gamepad.leftThumbstick.yAxis.value
            let rx = gamepad.rightThumbstick.xAxis.value, ry = gamepad.rightThumbstick.yAxis.value
            let menu = gamepad.buttonMenu.isPressed
            let options = gamepad.buttonOptions?.isPressed ?? false

            MainActor.assumeIsolated {
                let combo = l3 && r3
                // Home (or L3+R3 as a universal fallback) toggles the guide.
                if (home && !self.prevHome) || (combo && !self.prevCombo) { self.onGuideToggle?() }

                if self.isGuideOpen?() == true {
                    // Menu mode: freeze game input, edge-navigate the overlay.
                    self.driver.setPad([])
                    if down && !self.prevDown { self.onGuideMove?(true) }
                    else if up && !self.prevUp { self.onGuideMove?(false) }
                    if right && !self.prevRight { self.onGuideAdjust?(true) }
                    else if left && !self.prevLeft { self.onGuideAdjust?(false) }
                    if a && !self.prevA { self.onGuideActivate?() }
                    if bb && !self.prevB { self.onGuideClose?() }
                } else {
                    // Position-based face mapping (bottom/right/left/top), so PS1 shapes line up:
                    // A→✕ south, B→○ east, X→▢ west, Y→△ north. GBA cores keep only south/east.
                    var b: PadButtons = []
                    if a { b.insert(.south) }
                    if bb { b.insert(.east) }
                    if bx { b.insert(.west) }
                    if by { b.insert(.north) }
                    if lsh { b.insert(.l1) }
                    if rsh { b.insert(.r1) }
                    if lt { b.insert(.l2) }
                    if rt { b.insert(.r2) }
                    if l3 { b.insert(.l3) }
                    if r3 { b.insert(.r3) }
                    if up { b.insert(.up) }
                    if down { b.insert(.down) }
                    if left { b.insert(.left) }
                    if right { b.insert(.right) }
                    // Optionally let the left analog stick stand in for the D-pad (past a deadzone).
                    if self.joystickAsDpad {
                        let dz = GameControllerManager.stickDeadzone
                        if sy > dz { b.insert(.up) }
                        if sy < -dz { b.insert(.down) }
                        if sx < -dz { b.insert(.left) }
                        if sx > dz { b.insert(.right) }
                    }
                    if menu { b.insert(.start) }
                    if options { b.insert(.select) }
                    self.driver.setPad(b,
                                       leftX: Self.axis(sx), leftY: Self.axis(sy),
                                       rightX: Self.axis(rx), rightY: Self.axis(ry))
                }

                self.prevHome = home; self.prevCombo = combo
                self.prevUp = up; self.prevDown = down; self.prevLeft = left; self.prevRight = right
                self.prevA = a; self.prevB = bb
            }
        }
    }
}
