import EmulatorCore
import Foundation
import GBACore

// Milestone M1 — headless "it boots and runs frames" runner.
//
// Drives an EmulatorCore through a fixed number of frames with no window, exercising the
// full boundary (load / run / video / audio / input / save-state), then writes the final
// framebuffer to a PPM image so the output is eyeball-verifiable. Today it runs MockGBACore;
// once libmgba is wired, pass a real .gba path and the exact same loop runs the real core.
//
// Usage:  emu-boot [--rom <path>] [--frames N] [--out <file.ppm>]

struct Options {
    var romPath: String?
    var frames: Int = 60
    var outPath: String = "out/frame.ppm"
    var useRealCore = false
}

func parseOptions() -> Options {
    var opts = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--rom":    opts.romPath = it.next()
        case "--frames": if let v = it.next(), let n = Int(v) { opts.frames = n }
        case "--out":    if let v = it.next() { opts.outPath = v }
        case "--real":   opts.useRealCore = true
        default:
            FileHandle.standardError.write(Data("Unknown argument: \(arg)\n".utf8))
        }
    }
    return opts
}

func writePPM(_ pixels: [UInt32], width: Int, height: Int, to path: String) throws {
    var data = Data("P6\n\(width) \(height)\n255\n".utf8)
    data.reserveCapacity(data.count + width * height * 3)
    for px in pixels {
        data.append(UInt8(px & 0xFF))         // R
        data.append(UInt8((px >> 8) & 0xFF))  // G
        data.append(UInt8((px >> 16) & 0xFF)) // B
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

let opts = parseOptions()

let core: EmulatorCore = opts.useRealCore ? GBACore() : MockGBACore()
print("Using \(opts.useRealCore ? "real libmgba core" : "mock core")")
let (w, h) = core.videoSize
print("Core: \(type(of: core).system.displayName)  \(w)x\(h)  @\(type(of: core).system.refreshRate) Hz")

if let romPath = opts.romPath {
    do {
        try core.loadROM(at: URL(fileURLWithPath: romPath))
        print("Loaded ROM: \(romPath)")
    } catch {
        FileHandle.standardError.write(Data("Failed to load ROM: \(error)\n".utf8))
        exit(1)
    }
} else {
    print("No --rom given; running mock core with no cartridge.")
}

// Run the frame loop, draining audio each frame the way the real audio thread will.
var videoBuffer = [UInt32](repeating: 0, count: w * h)
let audioPerFrame = core.audioSampleRate / 60
var audioBuffer = [Int16](repeating: 0, count: audioPerFrame * 2)

// Press A on odd frames so input plumbing shows up in the output.
let start = Date()
for frame in 0..<opts.frames {
    core.setButtons(frame % 2 == 0 ? [] : [.a])
    core.runFrame()
    videoBuffer.withUnsafeMutableBufferPointer { core.copyVideo(into: $0.baseAddress!) }
    _ = audioBuffer.withUnsafeMutableBufferPointer {
        core.readAudio(into: $0.baseAddress!, maxFrames: audioPerFrame)
    }
}
let elapsed = Date().timeIntervalSince(start)

// Prove save-state round-trips.
let state = try core.saveState()
try core.loadState(state)
print("Save state: \(state.count) bytes, round-trip OK")

let fps = Double(opts.frames) / elapsed
print(String(format: "Ran %d frames in %.3fs (%.0f fps headless)", opts.frames, elapsed, fps))

try writePPM(videoBuffer, width: w, height: h, to: opts.outPath)
print("Wrote final framebuffer -> \(opts.outPath)")
