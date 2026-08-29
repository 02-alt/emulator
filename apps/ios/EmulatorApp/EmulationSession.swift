import Foundation
import UIKit
import EmulatorCore
import Synchronization

/// Drives an `EmulatorCore` on a dedicated high-priority thread at the system's refresh rate. It is
/// the single owner of the core (which is not `Sendable`): every core touch happens on the emulation
/// thread. The rest of the app interacts through thread-safe seams only:
///   - video out via `withLatestFrame` (double-buffered),
///   - input in via `setButtons`,
///   - audio drained into a ring buffer the `AudioOutput` reads on the audio thread,
///   - save-state / battery ops posted as commands run at a safe point between frames.
final class EmulationSession: @unchecked Sendable {
    let width: Int
    let height: Int

    private let core: EmulatorCore
    private let refreshRate: Double
    private let saveDirectory: URL?

    // Video: double-buffered framebuffers, swapped under `frameLock`.
    private var front: [UInt32]
    private var back: [UInt32]
    private let frameLock = NSLock()

    private var buttons = GBAButtons()
    private var luminance: UInt8 = 0        // solar-sensor light level, applied each frame (Boktai et al.)
    private let buttonLock = NSLock()

    /// Whether this game's cartridge has a solar sensor (drives the on-screen "light" button). Read
    /// once at init — the core already has its ROM loaded — so the UI can query it without touching
    /// the core off the emulation thread.
    let hasLightSensor: Bool

    // Playback state (speed multiplier + pause + rewind), read each iteration by the loop.
    private var speed = 1.0
    private var paused = false
    private var rewinding = false
    private var rewindEnabled = AppSettings.rewindEnabled   // off = capture no history (saves CPU/memory)
    private let stateLock = NSLock()

    // Rewind ring: periodic savestates (emulation-thread-only, so no lock needed). Holding rewind
    // pops these back through `loadState`. Interval/capacity trade history length against memory.
    private var rewindRing: [Data] = []
    private var frameCounter = 0
    private let rewindInterval = 6        // capture a state every 6 frames (~10/sec)
    private let rewindCapacity = 120      // ~12s of history

    // Audio: emulation thread writes drained samples into `ring`; `AudioOutput` reads them.
    let ring: AudioRingBuffer
    private let audio: AudioOutput
    private var audioScratch: [Int16]
    private let audioMaxFrames: Int
    private let audioSampleRate: Int

    // Commands to run on the emulation thread between frames (save/load state, battery flush).
    private var commands: [(EmulatorCore) -> Void] = []
    private let commandLock = NSLock()

    private var thread: Thread?            // main-thread-only (start/stop)
    // Written on main (start/stop), read every frame on the emulation thread — atomic so the loop's
    // `running` read is a well-defined cross-thread flag rather than a data race on a plain Bool.
    private let running = Atomic<Bool>(false)
    private let didStop = DispatchSemaphore(value: 0)   // signaled once the loop has fully exited

    init(core: EmulatorCore, saveDirectory: URL? = nil) {
        self.core = core
        self.saveDirectory = saveDirectory
        self.hasLightSensor = core.hasLightSensor
        (self.width, self.height) = core.videoSize
        self.refreshRate = type(of: core).system.refreshRate
        let count = width * height
        self.front = [UInt32](repeating: 0, count: count)
        self.back = [UInt32](repeating: 0, count: count)

        let rate = core.audioSampleRate
        self.audioSampleRate = rate
        // A quarter-second of headroom, plus a per-frame scratch generously sized.
        self.ring = AudioRingBuffer(frameCapacity: max(2048, rate / 4))
        self.audio = AudioOutput(ring: ring, sampleRate: rate)
        self.audioMaxFrames = Int(Double(rate) / refreshRate) + 64
        self.audioScratch = [Int16](repeating: 0, count: audioMaxFrames * 2)
    }

    // MARK: - Input

    func setButtons(_ b: GBAButtons) {
        buttonLock.lock(); buttons = b; buttonLock.unlock()
    }

    /// Set the solar-sensor light level (0 = dark … 255 = full sun). Applied before each frame.
    func setLuminance(_ value: UInt8) {
        buttonLock.lock(); luminance = value; buttonLock.unlock()
    }

    // MARK: - Playback

    /// Emulation speed multiplier (1 = real time). >1 fast-forwards; audio is muted while sped up
    /// since the ring can't keep pace with more-than-real-time output.
    func setSpeed(_ multiplier: Double) {
        stateLock.lock(); speed = max(0.25, multiplier); stateLock.unlock()
    }

    func setPaused(_ value: Bool) {
        stateLock.lock(); paused = value; stateLock.unlock()
    }

    /// Hold to rewind: while true, the loop replays buffered states backward instead of advancing.
    func setRewinding(_ value: Bool) {
        stateLock.lock(); rewinding = value; stateLock.unlock()
    }

    /// Toggle rewind capture. When off, no history is recorded (and the existing ring is dropped), so
    /// a player who never rewinds pays nothing for it.
    func setRewindEnabled(_ value: Bool) {
        stateLock.lock(); rewindEnabled = value; stateLock.unlock()
        if !value { enqueue { [weak self] _ in self?.rewindRing.removeAll(keepingCapacity: false) } }
    }

    /// Live master volume (0…1), applied to the audio engine immediately.
    func setVolume(_ value: Double) { audio.setVolume(value) }

    /// Reset to power-on state (keeps the loaded ROM). Runs on the emulation thread.
    func reset() {
        enqueue { [weak self] core in core.reset(); self?.rewindRing.removeAll(keepingCapacity: true) }
    }

    // MARK: - Video

    /// Run `body` with a pointer to the most recently completed frame (RGBA8888, top-left origin).
    func withLatestFrame(_ body: (UnsafePointer<UInt32>) -> Void) {
        frameLock.lock()
        front.withUnsafeBufferPointer { body($0.baseAddress!) }
        frameLock.unlock()
    }

    // MARK: - Lifecycle

    func start() {
        guard thread == nil else { return }
        // Load the cartridge battery save before the first frame (core is idle, safe to touch here).
        if let url = batteryURL, let data = try? Data(contentsOf: url) {
            core.loadSaveData(data)
        }
        audio.start()
        audio.setVolume(AppSettings.masterVolume)
        running.store(true, ordering: .sequentiallyConsistent)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "emulation"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        guard thread != nil else { return }
        persistBattery()          // queue a final battery flush before the loop exits
        running.store(false, ordering: .sequentiallyConsistent)
        // Wait for the emulation thread to finish its current frame AND its final battery flush
        // before returning: otherwise the next session could start reading a half-written save, and
        // the core could be touched after teardown (use-after-free). Bounded — the loop re-checks
        // `running` every frame — with a 2s safety cap in case the core ever wedges.
        _ = didStop.wait(timeout: .now() + 2)
        thread = nil
        audio.stop()
    }

    // MARK: - Save state + battery

    /// Post a battery (SRAM/flash) flush to disk. Safe to call from the UI thread; runs on the
    /// emulation thread, so it's consistent with the running game.
    func persistBattery() {
        guard let url = batteryURL else { return }
        enqueue { core in
            guard let data = core.saveData else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Write a full save state. `completion` is called on the main thread with success.
    func saveState(completion: @escaping (Bool) -> Void) {
        guard let url = stateURL else { completion(false); return }
        enqueue { core in
            let ok: Bool
            do { try core.saveState().write(to: url, options: .atomic); ok = true }
            catch { ok = false }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Restore a save state from raw data (e.g. a Continuity snapshot fetched from iCloud/disk).
    func loadStateData(_ data: Data, completion: @escaping (Bool) -> Void = { _ in }) {
        enqueue { [weak self] core in
            let ok: Bool
            do { try core.loadState(data); ok = true; self?.rewindRing.removeAll(keepingCapacity: true) }
            catch { ok = false }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Restore the last save state, if one exists.
    func loadState(completion: @escaping (Bool) -> Void) {
        guard let url = stateURL, let data = try? Data(contentsOf: url) else {
            completion(false); return
        }
        enqueue { [weak self] core in
            let ok: Bool
            do { try core.loadState(data); ok = true; self?.rewindRing.removeAll(keepingCapacity: true) }
            catch { ok = false }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    var hasSaveState: Bool {
        guard let url = stateURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Numbered save slots (multi-save, like the macOS "Save States" panel)

    /// Write a full save state to an explicit slot file, plus a PNG thumbnail of the current frame
    /// alongside it (so the slots panel can show a preview). `completion` runs on the main thread.
    func saveState(toSlotStateURL stateURL: URL, thumbURL: URL,
                   completion: @escaping (Bool) -> Void) {
        let thumb = latestFramePNG()
        enqueue { core in
            let ok: Bool
            do { try core.saveState().write(to: stateURL, options: .atomic); ok = true }
            catch { ok = false }
            if ok, let thumb { try? thumb.write(to: thumbURL, options: .atomic) }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Restore a full save state from an explicit slot file.
    func loadState(fromSlotStateURL url: URL, completion: @escaping (Bool) -> Void) {
        guard let data = try? Data(contentsOf: url) else { completion(false); return }
        enqueue { [weak self] core in
            let ok: Bool
            do { try core.loadState(data); ok = true; self?.rewindRing.removeAll(keepingCapacity: true) }
            catch { ok = false }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Continuity snapshot

    /// Capture a full save state plus a PNG of the latest frame, for cross-device "continue where you
    /// left off". The state is serialized on the emulation thread; `completion` runs on the main
    /// thread with (state, thumbnailPNG) — either may be nil on failure.
    func captureSnapshot(_ completion: @escaping (Data?, Data?) -> Void) {
        let thumbnail = latestFramePNG()
        enqueue { core in
            let state = try? core.saveState()
            DispatchQueue.main.async { completion(state, thumbnail) }
        }
    }

    /// PNG of the most recently completed frame. Thread-safe (copies under `frameLock`).
    func latestFramePNG() -> Data? {
        var pixels = [UInt32](repeating: 0, count: width * height)
        frameLock.lock(); pixels = front; frameLock.unlock()
        let w = width, h = height
        return pixels.withUnsafeMutableBytes { raw -> Data? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    // The core leaves the alpha byte at 0x00 (the Metal shader forces output alpha to 1,
                    // so the live picture is fine). Treat the frame as opaque RGBX here — using
                    // premultipliedLast instead makes every pixel fully transparent → a black thumbnail.
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let cg = ctx.makeImage()
            else { return nil }
            return UIImage(cgImage: cg).pngData()
        }
    }

    private func enqueue(_ command: @escaping (EmulatorCore) -> Void) {
        commandLock.lock(); commands.append(command); commandLock.unlock()
    }

    private var batteryURL: URL? { saveDirectory?.appendingPathComponent("battery.sav") }
    private var stateURL: URL? { saveDirectory?.appendingPathComponent("state.bin") }

    // MARK: - Loop

    private func loop() {
        defer { didStop.signal() }   // let stop() know the thread has fully exited (after the flush below)
        let baseInterval = 1.0 / refreshRate
        // Audio-master targets (in Int16 ring slots; a stereo frame = 2 slots). Keep ~4 video frames
        // of audio buffered; nudge the frame deadline to hold that fill so emulation tracks the audio
        // hardware clock instead of drifting against a wall-clock timer.
        let slotsPerFrame = Double(audioSampleRate) / refreshRate * 2
        let targetSlots = slotsPerFrame * 4
        var next = Date().timeIntervalSinceReferenceDate
        while running.load(ordering: .sequentiallyConsistent) {
            drainCommands()

            stateLock.lock()
            let speed = self.speed; let paused = self.paused
            let rewinding = self.rewinding; let rewindEnabled = self.rewindEnabled
            stateLock.unlock()

            if paused {
                // hold on the last frame
            } else if rewinding {
                // Replay recent snapshots backward (muted). If capture is disabled or history is
                // exhausted, hold on the current frame rather than advancing forward.
                if rewindEnabled, let state = rewindRing.popLast() {
                    try? core.loadState(state)
                    core.runFrame()
                    back.withUnsafeMutableBufferPointer { core.copyVideo(into: $0.baseAddress!) }
                    frameLock.lock(); swap(&front, &back); frameLock.unlock()
                    drainAudio(mute: true)   // muted while scrubbing backward
                }
            } else {
                buttonLock.lock(); let held = buttons; let lux = luminance; buttonLock.unlock()
                core.setButtons(held)
                if hasLightSensor { core.setLuminance(lux) }
                core.runFrame()

                back.withUnsafeMutableBufferPointer { core.copyVideo(into: $0.baseAddress!) }
                frameLock.lock(); swap(&front, &back); frameLock.unlock()

                // Drain the core's audio either way (so its internal buffer doesn't stall), but only
                // feed the ring at real time — muting while fast-forwarded.
                drainAudio(mute: speed > 1.0)

                if rewindEnabled { captureRewindStateIfNeeded() }
            }

            if !paused && !rewinding && speed == 1.0 {
                // Audio-master: gently correct the frame deadline toward the target ring fill. Since
                // the audio node always drains the ring while the engine runs, this locks the frame
                // rate to the audio clock and removes the slow drift that causes crackle/glitches.
                let error = (Double(ring.availableToRead) - targetSlots) / slotsPerFrame  // video-frames off
                let correction = max(-0.5, min(0.5, error * 0.1)) * baseInterval
                next += baseInterval + correction
            } else {
                next += paused ? baseInterval : baseInterval / speed
            }

            let now = Date().timeIntervalSinceReferenceDate
            let remaining = next - now
            if remaining > 0 {
                Thread.sleep(forTimeInterval: remaining)
            } else {
                next = now   // fell behind: reset rather than spiral
            }
        }
        // Final battery flush on the way out (view dismissed / app teardown).
        drainCommands()
        if let url = batteryURL, let data = core.saveData {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func drainCommands() {
        commandLock.lock()
        let pending = commands
        commands.removeAll(keepingCapacity: true)
        commandLock.unlock()
        for command in pending { command(core) }
    }

    private func captureRewindStateIfNeeded() {
        frameCounter += 1
        guard frameCounter % rewindInterval == 0, let state = try? core.saveState() else { return }
        rewindRing.append(state)
        if rewindRing.count > rewindCapacity { rewindRing.removeFirst() }
    }

    private func drainAudio(mute: Bool) {
        audioScratch.withUnsafeMutableBufferPointer { scratch in
            while true {
                let frames = core.readAudio(into: scratch.baseAddress!, maxFrames: audioMaxFrames)
                if frames <= 0 { break }
                if !mute { ring.write(scratch.baseAddress!, count: frames * 2) }
                if frames < audioMaxFrames { break }
            }
        }
    }
}
