import AppKit
import EmulatorCore
import MetalKit

/// MTKView that captures the keyboard and maps it to GBA buttons.
///
/// Game:   Arrows = D-pad · Z = A · X = B · A = L · S = R · Return = Start · RShift = Select
/// System: F5 quicksave · F9 quickload · Space = fast-forward (hold) · R = rewind (hold) · P = screenshot
///         ⌘, = Settings
@MainActor
final class EmulatorMetalView: MTKView {
    var driver: EmulationDriver?
    var onSave: (() -> Void)?          // F5 quicksave
    var onLoad: (() -> Void)?          // F9 quickload
    var onScreenshot: (() -> Void)?    // P
    var onOpenSettings: (() -> Void)?  // ⌘,
    var onExit: (() -> Void)?          // Esc → back to the library
    var onToggleLight: (() -> Void)?   // L toggles the solar sensor (set only for light-sensor carts)

    // Controller-guide overlay, also reachable/navigable from the keyboard (Tab opens; arrows move,
    // Return activates, Esc/Tab close). The pad drives the same overlay via GameControllerManager.
    var guideIsOpen: (() -> Bool)?
    var onToggleGuide: (() -> Void)?
    var onGuideMove: ((Bool) -> Void)?      // up/down — true = down/next
    var onGuideAdjust: ((Bool) -> Void)?    // left/right — true = right/increase
    var onGuideActivate: (() -> Void)?
    var onGuideClose: (() -> Void)?

    private var pressed: GBAButtons = []

    // The active keyCode → button map, read from Settings and refreshed live when the user rebinds.
    private var keyMap: [UInt16: GBAButtons] = Settings.shared.keyboardMap

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
    }
    required init(coder: NSCoder) { fatalError("not implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func settingsChanged() { keyMap = Settings.shared.keyboardMap }

    override func keyDown(with event: NSEvent) {
        // ⌘, opens Settings even on a direct-ROM launch (no menu bar / library present).
        if event.modifierFlags.contains(.command) {
            if event.keyCode == 43 { onOpenSettings?() }   // comma
            return
        }
        // While the guide is open it captures the keyboard: arrows move the focus, Return activates,
        // Esc/Tab close. Otherwise Tab opens it.
        if guideIsOpen?() == true {
            if !event.isARepeat {
                switch event.keyCode {
                case 126: onGuideMove?(false)     // Up
                case 125: onGuideMove?(true)      // Down
                case 123: onGuideAdjust?(false)   // Left
                case 124: onGuideAdjust?(true)    // Right
                case 36, 76: onGuideActivate?()   // Return / Enter
                case 48, 53: onGuideClose?()      // Tab / Esc
                default:     break
                }
            }
            return                                    // swallow all game keys while the guide is up
        }
        if !event.isARepeat, event.keyCode == 48 { onToggleGuide?(); return }   // Tab opens the guide
        switch event.keyCode {
        case 49: driver?.setFastForward(true); return  // Space (hold)
        case 15: driver?.setRewinding(true); return    // R (hold)
        default: break
        }
        if event.isARepeat { return }
        switch event.keyCode {
        case 96:  onSave?(); return         // F5
        case 101: onLoad?(); return         // F9
        case 35:  onScreenshot?(); return   // P
        case 53:  onExit?(); return         // Esc → back to the library
        case 37:  if let onToggleLight { onToggleLight(); return }   // L: solar sensor (light carts only)
        default:  break
        }
        guard let button = keyMap[event.keyCode] else {
            super.keyDown(with: event); return
        }
        pressed.insert(button)
        driver?.setKeyboard(pressed)
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 49: driver?.setFastForward(false); return  // Space
        case 15: driver?.setRewinding(false); return    // R
        default: break
        }
        guard let button = keyMap[event.keyCode] else {
            super.keyUp(with: event); return
        }
        pressed.remove(button)
        driver?.setKeyboard(pressed)
    }
}
