import Foundation

/// A system-agnostic controller snapshot — the superset of buttons any supported console needs, plus
/// two analog sticks. Cores map the subset they use: the GBA ignores the extra face buttons, shoulder
/// triggers, thumbstick clicks and sticks; the PS1 uses all of them. This is what replaces the
/// GBA-only `GBAButtons` at the input boundary as more systems land.
public struct PadButtons: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    // Face buttons, named by position so they're console-neutral. On the PS1 these are the shapes
    // (south = ✕ cross, east = ○ circle, west = ▢ square, north = △ triangle); on a GBA, A/B are
    // south/east.
    public static let south  = PadButtons(rawValue: 1 << 0)
    public static let east   = PadButtons(rawValue: 1 << 1)
    public static let west   = PadButtons(rawValue: 1 << 2)
    public static let north  = PadButtons(rawValue: 1 << 3)
    // D-pad.
    public static let up     = PadButtons(rawValue: 1 << 4)
    public static let down   = PadButtons(rawValue: 1 << 5)
    public static let left   = PadButtons(rawValue: 1 << 6)
    public static let right  = PadButtons(rawValue: 1 << 7)
    // Shoulders and triggers.
    public static let l1     = PadButtons(rawValue: 1 << 8)
    public static let r1     = PadButtons(rawValue: 1 << 9)
    public static let l2     = PadButtons(rawValue: 1 << 10)
    public static let r2     = PadButtons(rawValue: 1 << 11)
    // Thumbstick clicks.
    public static let l3     = PadButtons(rawValue: 1 << 12)
    public static let r3     = PadButtons(rawValue: 1 << 13)
    // Center.
    public static let start  = PadButtons(rawValue: 1 << 14)
    public static let select = PadButtons(rawValue: 1 << 15)

    /// The GBA-expressible subset, lifted into the neutral names (A→south, B→east, L/R→l1/r1).
    public init(gba: GBAButtons) {
        var b = PadButtons()
        if gba.contains(.a)      { b.insert(.south) }
        if gba.contains(.b)      { b.insert(.east) }
        if gba.contains(.l)      { b.insert(.l1) }
        if gba.contains(.r)      { b.insert(.r1) }
        if gba.contains(.up)     { b.insert(.up) }
        if gba.contains(.down)   { b.insert(.down) }
        if gba.contains(.left)   { b.insert(.left) }
        if gba.contains(.right)  { b.insert(.right) }
        if gba.contains(.start)  { b.insert(.start) }
        if gba.contains(.select) { b.insert(.select) }
        self = b
    }

    /// Project back onto the GBA's ten keys — the mapping a GBA core sees. Buttons a GBA lacks
    /// (west/north/triggers/thumb-clicks) simply drop out.
    public var gbaButtons: GBAButtons {
        var g = GBAButtons()
        if contains(.south)  { g.insert(.a) }
        if contains(.east)   { g.insert(.b) }
        if contains(.l1)     { g.insert(.l) }
        if contains(.r1)     { g.insert(.r) }
        if contains(.up)     { g.insert(.up) }
        if contains(.down)   { g.insert(.down) }
        if contains(.left)   { g.insert(.left) }
        if contains(.right)  { g.insert(.right) }
        if contains(.start)  { g.insert(.start) }
        if contains(.select) { g.insert(.select) }
        return g
    }
}

/// Held buttons plus two analog sticks. Stick axes are −32768…32767 with the **natural** convention:
/// +X = right, +Y = up. (Cores that follow other conventions — e.g. libretro's +Y = down — flip it
/// at their own boundary.) Sticks are 0 on controllers/systems without them.
public struct PadInput: Sendable {
    public var buttons: PadButtons
    public var leftX: Int16
    public var leftY: Int16
    public var rightX: Int16
    public var rightY: Int16

    public init(buttons: PadButtons = [],
                leftX: Int16 = 0, leftY: Int16 = 0,
                rightX: Int16 = 0, rightY: Int16 = 0) {
        self.buttons = buttons
        self.leftX = leftX; self.leftY = leftY
        self.rightX = rightX; self.rightY = rightY
    }

    public init(gba: GBAButtons) { self.init(buttons: PadButtons(gba: gba)) }

    /// The GBA-key projection, for cores that only understand `GBAButtons`.
    public var gbaButtons: GBAButtons { buttons.gbaButtons }
}
