import AVFoundation

/// iOS audio output: an `AVAudioEngine` whose source node pulls interleaved Int16 samples from the
/// emulation ring buffer on the real-time audio thread, and the engine resamples the core rate
/// (~32.8 kHz for the GBA) up to the hardware rate.
///
/// The one thing macOS doesn't need: an `AVAudioSession`. We configure `.playback` so the game is
/// audible even with the ring/silent switch, and handle interruptions (calls, Siri) + route changes
/// by pausing/resuming the engine.
final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let sourceNode: AVAudioSourceNode
    private let ring: AudioRingBuffer

    init(ring: AudioRingBuffer, sampleRate: Int) {
        self.ring = ring
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 2,
            interleaved: true
        ) else {
            fatalError("Unsupported audio format")
        }

        sourceNode = AVAudioSourceNode(format: format) { [ring] _, _, frameCount, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let need = Int(frameCount) * 2   // interleaved stereo slots
            guard let raw = abl[0].mData else { return noErr }
            let out = raw.assumingMemoryBound(to: Int16.self)
            let got = ring.read(into: out, count: need)
            if got < need {                  // underrun → fill the rest with silence
                for i in got..<need { out[i] = 0 }
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func start() {
        configureSession()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            // Non-fatal: the game still runs silently if audio can't start.
            print("AudioOutput: failed to start engine: \(error)")
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        engine.stop()
        // Intentionally do NOT deactivate the shared audio session here: the ambient player may still
        // be using it in the library, and deactivating would cut its sound off.
    }

    deinit {
        // Safety net: `start()` registers a `self`-targeting interruption observer that only `stop()`
        // removes. If an instance is ever released without `stop()` (an error path), the dangling
        // observer would crash on the next interruption — so tear it down here too.
        NotificationCenter.default.removeObserver(self)
        engine.stop()
    }

    /// Master output level, 0…1.
    func setVolume(_ volume: Double) {
        engine.mainMixerNode.outputVolume = Float(min(1, max(0, volume)))
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            engine.pause()
        case .ended:
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        @unknown default:
            break
        }
    }
}
