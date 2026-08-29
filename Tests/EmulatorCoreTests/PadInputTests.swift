import XCTest
@testable import EmulatorCore

final class PadInputTests: XCTestCase {
    /// Every GBA key must survive GBAButtons → PadButtons → GBAButtons unchanged, so routing the GBA
    /// input path through the new system-agnostic type doesn't alter what a GBA core receives.
    func testGBARoundTripIsIdentity() {
        let all: GBAButtons = [.a, .b, .select, .start, .right, .left, .up, .down, .r, .l]
        XCTAssertEqual(PadButtons(gba: all).gbaButtons, all)
        // And each single key on its own.
        for key in [GBAButtons.a, .b, .select, .start, .right, .left, .up, .down, .r, .l] {
            XCTAssertEqual(PadButtons(gba: key).gbaButtons, key)
        }
    }

    /// The default `setInput` must deliver exactly the GBA projection to a GBA-only core — i.e. the
    /// mock core reacts to `setInput([.south])` the same as `setButtons([.a])`.
    func testDefaultSetInputMatchesSetButtons() {
        func frame(_ apply: (MockGBACore) -> Void) -> [UInt32] {
            let core = MockGBACore()
            apply(core)
            core.runFrame()
            var buf = [UInt32](repeating: 0, count: core.videoSize.width * core.videoSize.height)
            buf.withUnsafeMutableBufferPointer { core.copyVideo(into: $0.baseAddress!) }
            return buf
        }
        XCTAssertEqual(frame { $0.setInput(PadInput(buttons: .south)) },
                       frame { $0.setButtons([.a]) })
        XCTAssertEqual(frame { $0.setInput(PadInput(buttons: [.south, .start])) },
                       frame { $0.setButtons([.a, .start]) })
        // A PS1-only button (square) has no GBA key, so it's a no-op for a GBA core.
        XCTAssertEqual(frame { $0.setInput(PadInput(buttons: .west)) },
                       frame { $0.setButtons([]) })
    }

    func testPS1OnlyButtonsDropFromGBAProjection() {
        let ps1: PadButtons = [.west, .north, .l2, .r2, .l3, .r3]
        XCTAssertEqual(ps1.gbaButtons, [])
    }
}
