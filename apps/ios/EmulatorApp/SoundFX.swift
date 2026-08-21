import AVFoundation

/// UI sound effects played through a dedicated `AVAudioEngine`, separate from the emulation output and
/// the ambient player, so a cue never interferes with a running game's audio. Ported from the macOS
/// `SoundFX`; iOS additionally needs an active `.playback` audio session for the cue to be audible.
///
/// Currently: the "received" cue — a soft, warm Rhodes electric-piano chord for an arriving transfer,
/// synthesized once at startup into a PCM buffer.
@MainActor
final class SoundFX {
    static let shared = SoundFX()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var receivedBuffer: AVAudioPCMBuffer?
    private var removedBuffer: AVAudioPCMBuffer?
    private var started = false

    private init() {
        receivedBuffer = Self.makeReceivedChime()
        removedBuffer = Self.makeRemovedSound()
        let format = receivedBuffer?.format
            ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Play the "removed" cue — a soft descending power-down for a deleted game (mirror of `received`).
    func playRemoved() {
        guard let buffer = removedBuffer else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if !started { try engine.start(); started = true }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !player.isPlaying { player.play() }
        } catch {
            print("SoundFX: engine start failed: \(error)")
        }
    }

    /// Synthesize the "removed" cue: a soft sine gliding *down* in pitch (a gentle power-down / eject)
    /// with a faint sub-octave, a quick attack and a smooth decay. Quiet and short — a tasteful "whoosh
    /// away," the sonic opposite of an ascending ding. Mirrors the macOS `SoundFX.makeRemovedSound`.
    private static func makeRemovedSound(sampleRate: Double = 44_100) -> AVAudioPCMBuffer? {
        let duration = 0.5
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(sampleRate * duration)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let n = Int(buffer.frameLength)
        let amp = 0.11, fStart = 523.25, fEnd = 155.56   // C5 → D#3, a downward drop
        let glide = 0.30
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let f = fStart * pow(fEnd / fStart, min(t / glide, 1.0))
            phase += 2 * .pi * f / sampleRate
            let attack = 0.005
            let e = t < attack ? t / attack : exp(-(t - attack) / 0.17)
            let body = sin(phase) + 0.3 * sin(0.5 * phase)
            let v = Float(amp * e * body)
            ch[0][i] = v; ch[1][i] = v
        }
        return buffer
    }

    /// Play the "received" cue — a soft, warm Rhodes electric-piano chord for an arriving transfer.
    /// Lazily starts the engine on first use; a failure is logged and swallowed (a missing sound effect
    /// must never take down the arrival animation).
    func playReceived() {
        guard let buffer = receivedBuffer else { return }
        do {
            // The cue may land in the Library with no game running, so make sure playback is live.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if !started { try engine.start(); started = true }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !player.isPlaying { player.play() }
        } catch {
            print("SoundFX: engine start failed: \(error)")
        }
    }

    /// Synthesize the "you received something" cue in the spirit of Daft Punk's "Something About Us":
    /// a soft, warm Rhodes electric-piano chord (a lush Dm9), struck gently and left to ring. Each voice
    /// is a mellow sine fundamental with a faint second harmonic for warmth and a quiet bell-like "tine"
    /// that fades quickly after the attack — the signature Rhodes shimmer. Quiet, rounded, intimate; a
    /// slight per-channel detune gives a soft chorus width. At the very end the chord is "aspirated":
    /// over the last ~0.35s its brightness closes down (the harmonics and tine roll off) as the level
    /// collapses, so it darkens and recedes as if pulled away — no pitch change. No filter sweep, no
    /// pump, no hard saturation — just a gentle chord that gets sucked into silence.
    private static func makeReceivedChime(sampleRate: Double = 44_100) -> AVAudioPCMBuffer? {
        let duration = 1.8
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(sampleRate * duration)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let n = Int(buffer.frameLength)

        // Dm9 voicing — mellow and jazzy, the warm-interlude mood.
        let chord = [146.83, 174.61, 220.0, 261.63, 329.63]   // D3 F3 A3 C4 E4
        let amp = 0.075

        // A Rhodes voice: soft sine fundamental + faint 2nd harmonic (warmth), plus a quiet high tine
        // that barks briefly on the attack (eTine) then dies away — the electric-piano shimmer. `bright`
        // scales the upper content (harmonic + tine) so the tone can be darkened without touching pitch.
        func voice(_ f: Double, _ t: Double, _ e: Double, _ eTine: Double, _ bright: Double) -> Double {
            let body = sin(2 * .pi * f * t) + 0.26 * bright * sin(2 * .pi * 2 * f * t)
            let tine = 0.09 * bright * sin(2 * .pi * 4.1 * f * t)
            return e * body + e * eTine * tine
        }

        let attack = 0.012, decay = 0.95, tineDecay = 0.16
        // The "aspiré" tail: over the last suckDur the brightness closes down and the level collapses,
        // so the chord darkens and recedes as if pulled away — no pitch change.
        let suckDur = 0.35, suckStart = duration - suckDur
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var e = t < attack ? t / attack : exp(-(t - attack) / decay)
            let eTine = exp(-t / tineDecay)
            var bright = 1.0
            if t >= suckStart {
                let p = (t - suckStart) / suckDur           // 0 → 1 across the suck
                e *= 0.5 * (1 - cos(.pi * (1 - p)))         // level 1 → 0, smooth at both ends
                bright = (1 - p) * (1 - p)                  // roll the highs off fast → darkening pull
            }
            var left = 0.0, right = 0.0
            for f in chord {
                left  += voice(f * 0.9992, t, e, eTine, bright)   // slight detune each side → chorus width
                right += voice(f * 1.0008, t, e, eTine, bright)
            }
            ch[0][i] = Float(amp * left)
            ch[1][i] = Float(amp * right)
        }
        return buffer
    }
}
