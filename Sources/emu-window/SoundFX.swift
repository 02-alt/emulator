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
    private var trophyBuffer: AVAudioPCMBuffer?
    private var receivedBuffer: AVAudioPCMBuffer?
    private var started = false

    private init() {
        cartridgeBuffer = Self.loadBuffer(resource: "cartridge-insert", ext: "caf")
        let format = cartridgeBuffer?.format
            ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        trophyBuffer = Self.makeTrophyChime()
        receivedBuffer = Self.makeReceivedChime()
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

    /// Play the trophy chime — a gentle, subtle two-note rise, synthesized (not a file).
    func playTrophy() {
        guard let buffer = trophyBuffer else { return }
        do {
            if !started { try engine.start(); started = true }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !player.isPlaying { player.play() }
        } catch { NSLog("SoundFX: engine start failed: \(error)") }
    }

    /// Play the "received" cue — a subtle, classy two-note glass chime for an arriving transfer.
    func playReceived() {
        guard let buffer = receivedBuffer else { return }
        do {
            if !started { try engine.start(); started = true }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !player.isPlaying { player.play() }
        } catch { NSLog("SoundFX: engine start failed: \(error)") }
    }

    /// Synthesize a minimalist "you received something" chime — the AirDrop-adjacent cue for an arriving
    /// game. Two soft glassy notes rising a gentle perfect fourth (D5 → G5), the second entering just
    /// after the first, each a sine plus faint higher partials for a bell-like sheen, with a soft attack
    /// and a long smooth decay. Very quiet, slightly stereo-widened (the upper note detuned a hair
    /// between channels) so it reads as "classy and understated," not a notification blast.
    private static func makeReceivedChime(sampleRate: Double = 44_100) -> AVAudioPCMBuffer? {
        // Long enough for the exponential decay to run out to near-silence before the buffer ends,
        // so the tail is never hard-clipped.
        let duration = 1.7
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(sampleRate * duration)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let n = Int(buffer.frameLength)
        let note1 = 587.33          // D5
        let note2 = 783.99          // G5 — a gentle perfect fourth up
        let note2Start = 0.11
        let amp = 0.11

        func env(_ dt: Double, decay: Double) -> Double {
            if dt < 0 { return 0 }
            let attack = 0.006
            return dt < attack ? dt / attack : exp(-(dt - attack) / decay)
        }
        // A soft glassy voice: fundamental + faint 2nd/3rd partials.
        func voice(_ f: Double, _ t: Double, _ e: Double) -> Double {
            amp * e * (sin(2 * .pi * f * t)
                       + 0.18 * sin(2 * .pi * f * 2 * t)
                       + 0.06 * sin(2 * .pi * f * 3 * t))
        }
        // A smooth cosine release over the final stretch, so whatever amplitude remains eases to a
        // true zero at the very end instead of clicking off.
        let release = 0.45
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let e1 = env(t, decay: 0.55)
            let t2 = t - note2Start
            let e2 = env(t2, decay: 0.55)
            let base = voice(note1, t, e1)
            // Detune the upper note a touch per channel for a subtle stereo shimmer.
            var left = base + voice(note2 - 0.8, t2, e2)
            var right = base + voice(note2 + 0.8, t2, e2)
            let remaining = duration - t
            if remaining < release {
                let taper = 0.5 * (1 - cos(.pi * remaining / release))   // 1 → 0, smooth at both ends
                left *= taper
                right *= taper
            }
            ch[0][i] = Float(left)
            ch[1][i] = Float(right)
        }
        return buffer
    }

    /// Synthesize a minimalist trophy chime: two soft sine notes a perfect fifth apart (A5 → E6),
    /// the second entering just after the first, each with a quick attack and a smooth exponential
    /// decay, plus a faint octave shimmer. Kept quiet and short so it reads as a subtle "ding," not a
    /// fanfare.
    private static func makeTrophyChime(sampleRate: Double = 44_100) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(sampleRate * 0.55)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let n = Int(buffer.frameLength)
        let note1 = 880.0, note2 = 1318.51, note2Start = 0.10
        let amp = 0.14

        func env(_ dt: Double, decay: Double) -> Double {
            if dt < 0 { return 0 }
            let attack = 0.004
            return dt < attack ? dt / attack : exp(-(dt - attack) / decay)
        }
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var s = 0.0
            let e1 = env(t, decay: 0.34)
            s += amp * e1 * sin(2 * .pi * note1 * t)
            s += amp * 0.22 * e1 * sin(2 * .pi * note1 * 2 * t)   // faint octave shimmer
            let t2 = t - note2Start
            let e2 = env(t2, decay: 0.34)
            s += amp * e2 * sin(2 * .pi * note2 * t2)
            s += amp * 0.22 * e2 * sin(2 * .pi * note2 * 2 * t2)
            let v = Float(s)
            ch[0][i] = v; ch[1][i] = v
        }
        return buffer
    }

    /// Decode a bundled audio resource into a single PCM buffer. Returns `nil` (logged) if the
    /// resource is missing or unreadable, so the caller can no-op gracefully.
    private static func loadBuffer(resource: String, ext: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.moduleResources?.url(forResource: resource, withExtension: ext) else {
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
