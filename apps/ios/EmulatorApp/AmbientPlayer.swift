import AVFoundation
import QuartzCore

/// Background ambience — loops a bundled field recording (rain, storm) through its own
/// `AVAudioEngine`, separate from the emulation output, so the chosen ambience plays the same in the
/// Library and mid-game. Ported from the macOS `AmbientPlayer`; driven by `AppSettings` — call
/// `apply()` at launch and whenever the ambient settings change.
///
/// Each scene is decoded once, capped in length, and equal-power crossfaded end→start so the loop is
/// seamless. Scene/volume changes are smoothed by fading the mixer level.
@MainActor
final class AmbientPlayer {
    static let shared = AmbientPlayer()

    private static let maxLoopSeconds = 90.0
    private static let crossfadeSeconds = 1.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    private var buffers: [AmbientScene: AVAudioPCMBuffer] = [:]
    private var current: AmbientScene = .off
    private var started = false

    private var fadeTimer: Timer?
    private var fadeStart: Float = 0
    private var fadeTarget: Float = 0
    private var fadeT0: CFTimeInterval = 0
    private var fadeDuration: Double = 0
    private var fadeCompletion: (() -> Void)?

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
    }

    /// Bring the player in line with the current settings. Call at launch and on every change.
    func apply() {
        let scene = AppSettings.ambientScene
        let target = Float(AppSettings.ambientVolume)
        if scene != current {
            current = scene
            switchTo(scene, volume: target)
        } else if scene != .off {
            fade(to: target, over: 0.08)
        }
    }

    // MARK: - Transport

    private func switchTo(_ scene: AmbientScene, volume: Float) {
        fade(to: 0, over: player.isPlaying ? 0.4 : 0) { [weak self] in
            guard let self else { return }
            self.player.stop()
            guard scene != .off, let buffer = self.buffer(for: scene) else { return }
            do {
                // The ambience needs an active playback session even when no game is running.
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                if !self.started { try self.engine.start(); self.started = true }
                self.player.scheduleBuffer(buffer, at: nil, options: [.loops, .interrupts])
                self.player.play()
                self.fade(to: volume, over: 0.6)
            } catch {
                print("AmbientPlayer: engine start failed: \(error)")
            }
        }
    }

    private func fade(to target: Float, over seconds: Double, then: (() -> Void)? = nil) {
        fadeTimer?.invalidate(); fadeTimer = nil
        fadeCompletion = nil
        guard seconds > 0 else { engine.mainMixerNode.outputVolume = target; then?(); return }
        fadeStart = engine.mainMixerNode.outputVolume
        fadeTarget = target
        fadeT0 = CACurrentMediaTime()
        fadeDuration = seconds
        fadeCompletion = then
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepFade() }
        }
    }

    private func stepFade() {
        let p = Float(min(1, (CACurrentMediaTime() - fadeT0) / fadeDuration))
        engine.mainMixerNode.outputVolume = fadeStart + (fadeTarget - fadeStart) * p
        guard p >= 1 else { return }
        fadeTimer?.invalidate(); fadeTimer = nil
        let done = fadeCompletion; fadeCompletion = nil
        done?()
    }

    // MARK: - Buffer cache

    private func buffer(for scene: AmbientScene) -> AVAudioPCMBuffer? {
        if let cached = buffers[scene] { return cached }
        guard let name = scene.resource,
              let built = Self.loadSeamlessLoop(resource: name, target: format) else { return nil }
        buffers[scene] = built
        return built
    }

    // MARK: - Loading

    private static func loadSeamlessLoop(resource: String, target: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Accept any bundled audio container (some loops are pre-trimmed AAC `.m4a` rather than mp3).
        let exts = ["mp3", "m4a", "caf"]
        guard let url = exts.lazy.compactMap({ ext in
            Bundle.main.url(forResource: resource, withExtension: ext)
                ?? Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: "Resources")
        }).first else {
            print("AmbientPlayer: missing resource \(resource).(mp3|m4a|caf)"); return nil
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            print("AmbientPlayer: could not open \(url.lastPathComponent)"); return nil
        }
        let srcFormat = file.processingFormat
        let cap = AVAudioFrameCount(min(Double(file.length), maxLoopSeconds * srcFormat.sampleRate))
        guard cap > 0, let raw = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: cap) else { return nil }
        do { try file.read(into: raw, frameCount: cap) }
        catch { print("AmbientPlayer: read failed for \(resource): \(error)"); return nil }

        let matched: AVAudioPCMBuffer
        if srcFormat.sampleRate == target.sampleRate && srcFormat.channelCount == target.channelCount {
            matched = raw
        } else if let converted = convert(raw, to: target) {
            matched = converted
        } else { return nil }
        return makeSeamless(matched)
    }

    private final class ConvertFeed: @unchecked Sendable {
        var fed = false
        let buffer: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private static func convert(_ input: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: input.format, to: target) else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let feed = ConvertFeed(input)
        var err: NSError?
        converter.convert(to: output, error: &err) { _, status in
            if feed.fed { status.pointee = .noDataNow; return nil }
            feed.fed = true; status.pointee = .haveData; return feed.buffer
        }
        if err != nil { return nil }
        return output
    }

    private static func makeSeamless(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sr = input.format.sampleRate
        let n = Int(input.frameLength)
        let xf = min(Int(crossfadeSeconds * sr), n / 3)
        guard xf > 0, n > xf, let inData = input.floatChannelData else { return input }
        let channels = Int(input.format.channelCount)
        let loopLen = n - xf
        guard let out = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: AVAudioFrameCount(loopLen)),
              let outData = out.floatChannelData else { return input }
        out.frameLength = AVAudioFrameCount(loopLen)
        for c in 0..<channels {
            let src = inData[c], dst = outData[c]
            for i in 0..<loopLen { dst[i] = src[i] }
            for j in 0..<xf {
                let x = Float(j) / Float(xf)
                dst[j] = src[j] * sinf(0.5 * .pi * x) + src[loopLen + j] * cosf(0.5 * .pi * x)
            }
        }
        return out
    }
}
