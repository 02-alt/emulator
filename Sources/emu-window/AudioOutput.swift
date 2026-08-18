import AVFoundation

/// AVAudioEngine output that pulls from the emulation ring buffer on the real-time audio thread.
/// The engine resamples our core-rate (e.g. 32.7kHz) interleaved Int16 to the hardware rate.
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

    func start() throws { try engine.start() }
    func stop() { engine.stop() }

    /// Master output level, 0…1 (driven by the Volume setting; safe to call live).
    func setVolume(_ volume: Double) {
        engine.mainMixerNode.outputVolume = Float(min(1, max(0, volume)))
    }
}
