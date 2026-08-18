import Foundation

/// GBA button state as a bitmask. Bit order matches libmgba's key indices exactly, so
/// `rawValue` can be handed straight to the core with no remapping.
public struct GBAButtons: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let a      = GBAButtons(rawValue: 1 << 0)
    public static let b      = GBAButtons(rawValue: 1 << 1)
    public static let select = GBAButtons(rawValue: 1 << 2)
    public static let start  = GBAButtons(rawValue: 1 << 3)
    public static let right  = GBAButtons(rawValue: 1 << 4)
    public static let left   = GBAButtons(rawValue: 1 << 5)
    public static let up     = GBAButtons(rawValue: 1 << 6)
    public static let down   = GBAButtons(rawValue: 1 << 7)
    public static let r      = GBAButtons(rawValue: 1 << 8)
    public static let l      = GBAButtons(rawValue: 1 << 9)
}
