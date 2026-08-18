import XCTest
@testable import EmulatorCore

final class MockGBACoreTests: XCTestCase {
    func testVideoSizeIsGBANative() {
        let core = MockGBACore()
        XCTAssertEqual(core.videoSize.width, 240)
        XCTAssertEqual(core.videoSize.height, 160)
    }

    func testRunFrameProducesChangingOutput() {
        let core = MockGBACore()
        let count = core.videoSize.width * core.videoSize.height
        var a = [UInt32](repeating: 0, count: count)
        var b = [UInt32](repeating: 0, count: count)

        core.runFrame()
        a.withUnsafeMutableBufferPointer { core.copyVideo(into: $0.baseAddress!) }
        core.runFrame()
        b.withUnsafeMutableBufferPointer { core.copyVideo(into: $0.baseAddress!) }

        XCTAssertNotEqual(a, b, "Framebuffer should animate between frames")
    }

    func testButtonsChangeOutput() {
        let core = MockGBACore()
        let count = core.videoSize.width * core.videoSize.height
        var released = [UInt32](repeating: 0, count: count)
        var pressed = [UInt32](repeating: 0, count: count)

        core.setButtons([])
        core.runFrame()
        released.withUnsafeMutableBufferPointer { core.copyVideo(into: $0.baseAddress!) }

        core.reset()
        core.setButtons([.a])
        core.runFrame()
        pressed.withUnsafeMutableBufferPointer { core.copyVideo(into: $0.baseAddress!) }

        XCTAssertNotEqual(released, pressed, "Held buttons should affect output")
    }

    func testSaveStateRoundTrips() throws {
        let core = MockGBACore()
        for _ in 0..<10 { core.runFrame() }
        let state = try core.saveState()

        for _ in 0..<5 { core.runFrame() }
        try core.loadState(state)

        let restored = try core.saveState()
        XCTAssertEqual(state, restored, "Loading a state should restore exact machine state")
    }

    func testAudioIsProducedAfterFrame() {
        let core = MockGBACore()
        core.runFrame() // audio becomes available only after a frame is emulated
        let frames = core.audioSampleRate / 60
        var buf = [Int16](repeating: 0, count: frames * 2)
        let written = buf.withUnsafeMutableBufferPointer {
            core.readAudio(into: $0.baseAddress!, maxFrames: frames)
        }
        XCTAssertEqual(written, frames)
        XCTAssertTrue(buf.contains { $0 != 0 }, "Audio should be non-silent")
    }

    func testNoAudioBeforeFrame() {
        let core = MockGBACore()
        var buf = [Int16](repeating: 0, count: 64)
        let written = buf.withUnsafeMutableBufferPointer {
            core.readAudio(into: $0.baseAddress!, maxFrames: 32)
        }
        XCTAssertEqual(written, 0, "No audio should be available before any frame runs")
    }
}
