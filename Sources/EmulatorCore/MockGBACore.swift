import Foundation

/// A stand-in GBA core with no real emulation. It exists so the render/audio/input/library
/// pipelines can be developed and tested against the exact `EmulatorCore` boundary the real
/// libmgba core will use. It renders an animated test pattern that reacts to input and emits
/// a steady tone, which is enough to validate the whole app end-to-end before the FFI lands.
public final class MockGBACore: EmulatorCore {
    public static let system: EmulatedSystem = .gba

    public let videoSize: (width: Int, height: Int)
    public let audioSampleRate: Int

    private var frameIndex: Int = 0
    private var buttons: GBAButtons = []
    private var framebuffer: [UInt32]
    private var audioPhase: Double = 0
    private var audioAvailFrames: Int = 0   // audio produced by runFrame, waiting to be drained
    private var romName: String = "<none>"

    public init() {
        self.videoSize = EmulatedSystem.gba.nativeResolution
        self.audioSampleRate = 32_768
        self.framebuffer = [UInt32](repeating: 0, count: videoSize.width * videoSize.height)
    }

    public func loadROM(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EmulatorCoreError.romNotFound(url)
        }
        romName = url.lastPathComponent
        reset()
    }

    public func loadBIOS(at url: URL) throws { /* mock ignores BIOS */ }

    public func reset() {
        frameIndex = 0
        audioPhase = 0
        audioAvailFrames = 0
    }

    public func runFrame() {
        // Held buttons tint the pattern so input wiring is visibly verifiable.
        let rBias: Int = buttons.contains(.a) ? 96 : 0
        let gBias: Int = buttons.contains(.b) ? 96 : 0
        let bBias: Int = buttons.contains(.start) ? 96 : 0

        let (w, h) = videoSize
        let t = frameIndex
        for y in 0..<h {
            for x in 0..<w {
                // Scrolling diagonal gradient — clearly animated frame to frame.
                let r = UInt8(clamping: (x + t) & 0xFF + rBias)
                let g = UInt8(clamping: (y + t) & 0xFF + gBias)
                let b = UInt8(clamping: ((x ^ y) + t) & 0xFF + bBias)
                framebuffer[y * w + x] = Self.packRGBA(r, g, b)
            }
        }
        frameIndex += 1
        // Produce ~one video-frame's worth of audio, to be drained via readAudio (like a real core).
        audioAvailFrames += audioSampleRate / 60
    }

    public func copyVideo(into buffer: UnsafeMutablePointer<UInt32>) {
        framebuffer.withUnsafeBufferPointer { src in
            buffer.update(from: src.baseAddress!, count: src.count)
        }
    }

    public func readAudio(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int {
        // Drain up to what runFrame produced; 440 Hz tone, stereo interleaved.
        let n = min(maxFrames, audioAvailFrames)
        let step = 2.0 * Double.pi * 440.0 / Double(audioSampleRate)
        for f in 0..<n {
            let sample = Int16(Double(Int16.max) * 0.2 * sin(audioPhase))
            buffer[f * 2] = sample
            buffer[f * 2 + 1] = sample
            audioPhase += step
            if audioPhase > 2.0 * Double.pi { audioPhase -= 2.0 * Double.pi }
        }
        audioAvailFrames -= n
        return n
    }

    public func setButtons(_ buttons: GBAButtons) { self.buttons = buttons }

    // Minimal but real: state round-trips through the frame counter so save/load is testable.
    public func saveState() throws -> Data {
        var idx = UInt64(frameIndex).littleEndian
        return Data(bytes: &idx, count: MemoryLayout<UInt64>.size)
    }

    public func loadState(_ data: Data) throws {
        guard data.count == MemoryLayout<UInt64>.size else {
            throw EmulatorCoreError.stateIncompatible
        }
        let value = data.withUnsafeBytes { $0.load(as: UInt64.self) }
        frameIndex = Int(UInt64(littleEndian: value))
    }

    public var saveData: Data? { nil }
    public func loadSaveData(_ data: Data) { /* mock has no cartridge save */ }
}
