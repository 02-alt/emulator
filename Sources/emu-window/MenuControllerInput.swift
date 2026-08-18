import GameController

/// Drives the library menu (the cartridge carousel) from a connected controller, so the whole shelf
/// can be navigated and games launched without ever touching the keyboard.
///
/// It deliberately coexists with the in-game ``GameControllerManager``: that one owns the gamepad's
/// single `valueChangedHandler`, while this uses the *per-element* `pressedChangedHandler`/axis
/// handlers (separate slots), so both can be installed on the same physical controller at once. While
/// a game is playing inside the library window we simply flip ``isActive`` off, so a stray D-pad tap
/// can't scrub the carousel hidden behind the running game.
///
/// Handlers are pinned to the main queue and capture `self` weakly; `deinit` clears them so a handler
/// on a system-shared (long-lived) controller can't fire into freed memory.
final class MenuControllerInput: @unchecked Sendable {
    /// ← / D-pad-left / left-stick-left — previous cartridge.
    var onLeft: (@MainActor () -> Void)?
    /// → / D-pad-right / left-stick-right — next cartridge.
    var onRight: (@MainActor () -> Void)?
    /// A (cross) / Menu (start) — launch the centered cartridge.
    var onSelect: (@MainActor () -> Void)?
    /// X (square) — open Settings.
    var onSettings: (@MainActor () -> Void)?

    /// When false, all controller input is ignored (e.g. while a game plays in the same window).
    var isActive = true

    private var attached: [GCController] = []
    /// Hysteresis latch for the analog stick, so holding it left/right steps exactly once per push
    /// instead of firing every frame the axis reports.
    private var stickLatched = false

    private enum Action { case left, right, select, settings }

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerConnected(_:)),
            name: .GCControllerDidConnect, object: nil)
        for controller in GCController.controllers() { attach(controller) }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for controller in attached { detach(controller) }
    }

    @objc private func controllerConnected(_ note: Notification) {
        if let controller = note.object as? GCController { attach(controller) }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        controller.handlerQueue = .main
        attached.append(controller)

        pad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.fire(.left) }
        }
        pad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.fire(.right) }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.fire(.select) }
        }
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.fire(.select) }
        }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.fire(.settings) }
        }
        pad.leftThumbstick.xAxis.valueChangedHandler = { [weak self] _, value in
            self?.handleStick(value)
        }
    }

    /// Clear every handler we installed (see the type doc — controllers outlive this manager).
    private func detach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.dpad.left.pressedChangedHandler = nil
        pad.dpad.right.pressedChangedHandler = nil
        pad.buttonA.pressedChangedHandler = nil
        pad.buttonMenu.pressedChangedHandler = nil
        pad.buttonX.pressedChangedHandler = nil
        pad.leftThumbstick.xAxis.valueChangedHandler = nil
    }

    /// Handlers run on `.main` (see `handlerQueue`), so it's safe to hop onto the main actor here.
    private func fire(_ action: Action) {
        MainActor.assumeIsolated {
            guard isActive else { return }
            switch action {
            case .left: onLeft?()
            case .right: onRight?()
            case .select: onSelect?()
            case .settings: onSettings?()
            }
        }
    }

    private func handleStick(_ value: Float) {
        MainActor.assumeIsolated {
            let press: Float = 0.6     // must cross this to register a step
            let release: Float = 0.3   // must fall back under this before another step can fire
            guard isActive else { stickLatched = false; return }
            if !stickLatched {
                if value >= press { stickLatched = true; onRight?() }
                else if value <= -press { stickLatched = true; onLeft?() }
            } else if abs(value) < release {
                stickLatched = false
            }
        }
    }
}
