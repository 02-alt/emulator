import EmulatorCore
import Foundation

/// User-tunable preferences, persisted in `UserDefaults`. Deliberately small — just the handful of
/// options a GBA player actually reaches for (display crispness, master volume, rewind, auto-resume)
/// plus the RetroAchievements login (which lives in `RACredentials`). No sprawling per-core option
/// tree: only what's needed.
///
/// Writes persist immediately and post ``didChange`` so a live play session picks a change up
/// mid-game (volume, filter, rewind) without a restart. Values read on the emulation thread are
/// pushed in explicitly (see `EmulationDriver.setRewindEnabled`); everything else is read on the
/// main actor.
@MainActor
final class Settings {
    static let shared = Settings()

    /// Posted (on the main queue) whenever any stored value changes.
    nonisolated static let didChange = Notification.Name("EmulatorSettingsDidChange")

    /// How the framebuffer is sampled when scaled up to the window.
    enum DisplayFilter: Int, CaseIterable {
        case sharp = 0    // nearest-neighbor — crisp, unfiltered pixels (default)
        case smooth = 1   // bilinear — softens the image
        case lcd = 2      // physically-modelled GBA LCD: color correction + subpixel grid + ghosting
        var title: String {
            switch self {
            case .sharp: "Sharp"
            case .smooth: "Smooth"
            case .lcd: "LCD"
            }
        }
    }

    /// A procedurally-synthesized background ambience (see ``AmbientPlayer``). Plays in the Library
    /// and in-game alike, independent of the emulator's own audio.
    enum AmbientScene: Int, CaseIterable {
        case off = 0, rain, storm, cabin, park, shore
        var title: String {
            switch self {
            case .off: "Off"
            case .rain: "Rain"
            case .storm: "Storm"
            case .cabin: "Cabin"
            case .park: "Park"
            case .shore: "Shore"
            }
        }
    }

    /// Which corner the in-game performance overlay pins to (when ``showStats`` is on).
    enum StatsCorner: Int, CaseIterable {
        case topLeft = 0, topRight, bottomLeft, bottomRight
        var title: String {
            switch self {
            case .topLeft: "Top Left"
            case .topRight: "Top Right"
            case .bottomLeft: "Bottom Left"
            case .bottomRight: "Bottom Right"
            }
        }
    }

    /// A remappable GBA input. Each maps to a single ``GBAButtons`` flag and ships with the classic
    /// default key (arrows = D-pad · Z=A · X=B · A=L · S=R · Return=Start · Right Shift=Select).
    enum PadInput: String, CaseIterable {
        case up, down, left, right, a, b, l, r, start, select

        var button: GBAButtons {
            switch self {
            case .up: .up; case .down: .down; case .left: .left; case .right: .right
            case .a: .a; case .b: .b; case .l: .l; case .r: .r
            case .start: .start; case .select: .select
            }
        }
        var title: String {
            switch self {
            case .up: "Up"; case .down: "Down"; case .left: "Left"; case .right: "Right"
            case .a: "A"; case .b: "B"; case .l: "L"; case .r: "R"
            case .start: "Start"; case .select: "Select"
            }
        }
        var defaultKeyCode: UInt16 {
            switch self {
            case .up: 126; case .down: 125; case .left: 123; case .right: 124
            case .a: 6; case .b: 7; case .l: 0; case .r: 1
            case .start: 36; case .select: 60
            }
        }
    }

    private let defaults = UserDefaults.standard

    private enum Key {
        static let displayFilter = "video.displayFilter"
        static let lcdBacklit = "video.lcdBacklit"
        static let lcdGhosting = "video.lcdGhosting"
        static let volume = "audio.volume"
        static let ambientScene = "audio.ambientScene"
        static let ambientVolume = "audio.ambientVolume"
        static let rewindEnabled = "emu.rewindEnabled"
        static let runAhead = "emu.runAhead"
        static let autoResume = "emu.autoResume"
        static let showStats = "emu.showStats"
        static let statsCorner = "emu.statsCorner"
        static let keyBindings = "input.keyBindings"
        static let swapAB = "input.swapAB"
        static let joystickAsDpad = "input.joystickAsDpad"
        static let trophyNotifications = "achievements.notifications"
        static let psxInternalScale = "ps1.internalScale"
        static let psxWidescreen = "ps1.widescreen"
    }

    private init() {
        // First-run defaults: a fresh install starts crisp, full-volume, ambience off (but at a
        // sensible level once chosen), rewind + auto-resume on.
        defaults.register(defaults: [
            Key.displayFilter: DisplayFilter.sharp.rawValue,
            Key.lcdBacklit: true,
            Key.lcdGhosting: true,
            Key.volume: 1.0,
            Key.ambientScene: AmbientScene.off.rawValue,
            Key.ambientVolume: 0.6,
            Key.rewindEnabled: true,
            Key.autoResume: true,
            Key.showStats: false,
            Key.statsCorner: StatsCorner.topLeft.rawValue,
            Key.joystickAsDpad: true,
            Key.trophyNotifications: true,
            Key.psxInternalScale: 2,   // PS1 defaults to a safe, sharp 2× internal resolution
        ])
    }

    /// PlayStation internal render scale (1 = native, 2 = 2×, 4 = 4×, 8 = 8×). Higher is sharper 3D
    /// at a CPU cost. Applied when a PS1 game is next launched.
    var psxInternalScale: Int {
        get { let v = defaults.integer(forKey: Key.psxInternalScale); return v == 0 ? 2 : v }
        set { defaults.set(newValue, forKey: Key.psxInternalScale); changed() }
    }

    /// PlayStation widescreen hack: render 3D anamorphically at 16:9. Best for fully-3D games; 2D
    /// elements stretch. Applied when a PS1 game is next launched.
    var psxWidescreen: Bool {
        get { defaults.bool(forKey: Key.psxWidescreen) }
        set { defaults.set(newValue, forKey: Key.psxWidescreen); changed() }
    }

    var displayFilter: DisplayFilter {
        get { DisplayFilter(rawValue: defaults.integer(forKey: Key.displayFilter)) ?? .sharp }
        set { defaults.set(newValue.rawValue, forKey: Key.displayFilter); changed() }
    }

    /// LCD panel model (only affects the ``DisplayFilter/lcd`` filter): `true` = bright backlit SP
    /// (AGS-101), `false` = the dim, washed original GBA / SP AGS-001. Drives the color-mangler's
    /// screen-darken amount.
    var lcdBacklit: Bool {
        get { defaults.bool(forKey: Key.lcdBacklit) }
        set { defaults.set(newValue, forKey: Key.lcdBacklit); changed() }
    }

    /// Interframe blending for the ``DisplayFilter/lcd`` filter — reproduces the real panel's slow
    /// pixel response (LCD ghosting), which several GBA games relied on for flicker-based effects.
    var lcdGhosting: Bool {
        get { defaults.bool(forKey: Key.lcdGhosting) }
        set { defaults.set(newValue, forKey: Key.lcdGhosting); changed() }
    }

    /// Master output volume, 0…1.
    var volume: Double {
        get { min(1, max(0, defaults.double(forKey: Key.volume))) }
        set { defaults.set(min(1, max(0, newValue)), forKey: Key.volume); changed() }
    }

    /// Which background ambience plays (or ``AmbientScene/off``).
    var ambientScene: AmbientScene {
        get { AmbientScene(rawValue: defaults.integer(forKey: Key.ambientScene)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.ambientScene); changed() }
    }

    /// Background-ambience level, 0…1 (independent of the master ``volume``).
    var ambientVolume: Double {
        get { min(1, max(0, defaults.double(forKey: Key.ambientVolume))) }
        set { defaults.set(min(1, max(0, newValue)), forKey: Key.ambientVolume); changed() }
    }

    /// Whether the emulation thread keeps a rewind history (hold **R** in-game to scrub back).
    var rewindEnabled: Bool {
        get { defaults.bool(forKey: Key.rewindEnabled) }
        set { defaults.set(newValue, forKey: Key.rewindEnabled); changed() }
    }

    /// Run-ahead: display one frame into the future to cut input lag (~16ms), at a small CPU cost.
    /// Off by default (opt-in).
    var runAhead: Bool {
        get { defaults.bool(forKey: Key.runAhead) }
        set { defaults.set(newValue, forKey: Key.runAhead); changed() }
    }

    /// Whether opening a game restores where you left off (suspend state), vs. booting fresh.
    var autoResume: Bool {
        get { defaults.bool(forKey: Key.autoResume) }
        set { defaults.set(newValue, forKey: Key.autoResume); changed() }
    }

    /// Whether to post a system notification when a RetroAchievement is unlocked.
    var trophyNotifications: Bool {
        get { defaults.bool(forKey: Key.trophyNotifications) }
        set { defaults.set(newValue, forKey: Key.trophyNotifications); changed() }
    }

    /// Whether the in-game performance overlay (FPS · speed · draw rate) is shown in a corner.
    var showStats: Bool {
        get { defaults.bool(forKey: Key.showStats) }
        set { defaults.set(newValue, forKey: Key.showStats); changed() }
    }

    /// Which corner the performance overlay pins to.
    var statsCorner: StatsCorner {
        get { StatsCorner(rawValue: defaults.integer(forKey: Key.statsCorner)) ?? .topLeft }
        set { defaults.set(newValue.rawValue, forKey: Key.statsCorner); changed() }
    }

    // MARK: - Controls

    /// The key currently bound to a GBA input (its default if the user hasn't remapped it).
    func keyCode(for input: PadInput) -> UInt16 {
        if let dict = defaults.dictionary(forKey: Key.keyBindings),
           let v = dict[input.rawValue] as? Int { return UInt16(v) }
        return input.defaultKeyCode
    }

    /// Bind `code` to `input` (live: the play session rebuilds its key map on ``didChange``).
    func setKeyCode(_ code: UInt16, for input: PadInput) {
        var dict = defaults.dictionary(forKey: Key.keyBindings) ?? [:]
        dict[input.rawValue] = Int(code)
        defaults.set(dict, forKey: Key.keyBindings)
        changed()
    }

    /// Forget every custom binding, restoring the classic defaults.
    func resetKeyBindings() { defaults.removeObject(forKey: Key.keyBindings); changed() }

    /// The keyCode → GBA button map the play window feeds the emulator.
    var keyboardMap: [UInt16: GBAButtons] {
        var map: [UInt16: GBAButtons] = [:]
        for input in PadInput.allCases { map[keyCode(for: input)] = input.button }
        return map
    }

    /// Swap the A and B buttons (keyboard + gamepad) — applied in the driver's input merge.
    var swapAB: Bool {
        get { defaults.bool(forKey: Key.swapAB) }
        set { defaults.set(newValue, forKey: Key.swapAB); changed() }
    }

    /// Whether a controller's left analog stick also drives the D-pad, so you can steer with the
    /// joystick. On by default; turn it off to leave the stick unmapped (D-pad only).
    var joystickAsDpad: Bool {
        get { defaults.bool(forKey: Key.joystickAsDpad) }
        set { defaults.set(newValue, forKey: Key.joystickAsDpad); changed() }
    }

    /// A human-readable name for a macOS key code (for the bindings UI).
    static func keyName(for code: UInt16) -> String { keyNames[code] ?? "Key \(code)" }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        56: "⇧ Left", 60: "⇧ Right", 59: "⌃ Ctrl", 58: "⌥ Option", 55: "⌘ Cmd",
        50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
    ]

    private func changed() {
        NotificationCenter.default.post(name: Settings.didChange, object: self)
    }
}
