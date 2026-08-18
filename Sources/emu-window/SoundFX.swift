import AVFoundation

/// UI sound effects played through a dedicated `AVAudioEngine` (separate from the emulation output),
/// so a launch cue never interferes with the running core's audio.
///
/// Currently: the "cha-chunk" of a cartridge seating into the slot — a recorded SNES cartridge
/// insert, cropped to just the insertion gesture (`Resources/cartridge-insert.caf`). Played when a
/// GBA game is launched. The clip is decoded once at startup into a PCM buffer.
@MainActor
final class SoundFX {
    static let shared = SoundFX()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var cartridgeBuffer: AVAudioPCMBuffer?
    private var started = false

    private init() {
        cartridgeBuffer = Self.loadBuffer(resource: "cartridge-insert", ext: "caf")
        let format = cartridgeBuffer?.format
            ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Play the cartridge-insertion cue. Lazily starts the engine on first use; a failure is logged
    /// and swallowed (a missing sound effect must never take down a game launch).
    func playCartridgeInsert() {
        guard let buffer = cartridgeBuffer else { return }
        do {
            if !started { try engine.start(); started = true }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !player.isPlaying { player.play() }
        } catch {
            NSLog("SoundFX: engine start failed: \(error)")
        }
    }

    /// Decode a bundled audio resource into a single PCM buffer. Returns `nil` (logged) if the
    /// resource is missing or unreadable, so the caller can no-op gracefully.
    private static func loadBuffer(resource: String, ext: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.module.url(forResource: resource, withExtension: ext) else {
            NSLog("SoundFX: missing resource \(resource).\(ext)"); return nil
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            NSLog("SoundFX: could not open \(resource).\(ext)"); return nil
        }
        let cap = AVAudioFrameCount(file.length)
        guard cap > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap) else {
            NSLog("SoundFX: empty buffer for \(resource).\(ext)"); return nil
        }
        do { try file.read(into: buffer) }
        catch { NSLog("SoundFX: read failed for \(resource): \(error)"); return nil }
        return buffer
    }
}
