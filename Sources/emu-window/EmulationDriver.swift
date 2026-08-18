import EmulatorCore
import Foundation
import Synchronization

/// Runs the core on a dedicated thread, paced by audio consumption (audio-master sync): it only
/// advances a frame when the audio ring has room, so the emulator runs at true hardware speed and
/// the audio buffer never drifts. Publishes the latest framebuffer for the renderer, and merges
/// keyboard + gamepad input. The core is confined to the emulation thread after `start()`.
final class EmulationDriver: @unchecked Sendable {
    let width: Int
    let height: Int
    let sampleRate: Int
    let ring: AudioRingBuffer

    private let core: EmulatorCore
    private let kbButtons = Atomic<UInt16>(0)
    private let padButtons = Atomic<UInt16>(0)
    private let touchButtons = Atomic<UInt16>(0)   // on-screen clickable controls
    private let running = Atomic<Bool>(false)
    private let paused = Atomic<Bool>(false)
    private let fastForward = Atomic<Bool>(false)
    private let speedMilli = Atomic<Int>(1000)   // playback speed ×1000 (1000 = 1×, 1500 = 1.5×, …)
    private let swapAB = Atomic<Bool>(false)      // swap the A/B buttons in the input merge
    private let rewinding = Atomic<Bool>(false)
    private let rewindEnabled = Atomic<Bool>(true)   // off = no history captured (saves CPU/memory)

    // Rewind: a bounded ring of recent save states, captured on the emulation thread.
    private var rewindStates: [Data] = []
    private let rewindInterval = 6      // snapshot every N frames (~10 snapshots/sec)
    private let rewindMax = 150         // ~15s of history
    private var frameCounter = 0

    private let frameLock = NSLock()
    private var latestFrame: [UInt32]
    private var producerFrame: [UInt32]
    private var audioScratch: [Int16]

    // Commands run on the emulation thread so the core stays single-threaded (save/load state,
    // battery clone/restore). Drained at the top of every loop iteration.
    private let cmdLock = NSLock()
    private var commands: [(EmulatorCore) -> Void] = []

    private var thread: Thread?
    private let didStop = DispatchSemaphore(value: 0)   // signaled when runLoop actually exits

    init(core: EmulatorCore) {
        self.core = core
        (width, height) = core.videoSize
        sampleRate = core.audioSampleRate
        latestFrame = [UInt32](repeating: 0, count: width * height)
        producerFrame = [UInt32](repeating: 0, count: width * height)
        ring = AudioRingBuffer(frameCapacity: 8192)          // ~250ms headroom at 32.7kHz
        audioScratch = [Int16](repeating: 0, count: 4096)    // 2048 stereo frames of scratch
    }

    // Input (thread-safe; called from main). Keyboard, pad and on-screen touch are OR-merged.
    func setKeyboard(_ b: GBAButtons) { kbButtons.store(b.rawValue, ordering: .relaxed) }
    func setPad(_ b: GBAButtons) { padButtons.store(b.rawValue, ordering: .relaxed) }
    func setTouch(_ b: GBAButtons) { touchButtons.store(b.rawValue, ordering: .relaxed) }

    func setPaused(_ on: Bool) { paused.store(on, ordering: .relaxed) }
    var isPaused: Bool { paused.load(ordering: .relaxed) }
    func setFastForward(_ on: Bool) { fastForward.store(on, ordering: .relaxed) }
    /// A finite playback speed (1.0 = real time, 1.5, 2.0…). Video-timed, audio muted above 1×.
    func setSpeed(_ multiplier: Double) { speedMilli.store(Int(multiplier * 1000), ordering: .relaxed) }
    func setSwapAB(_ on: Bool) { swapAB.store(on, ordering: .relaxed) }
    func setRewinding(_ on: Bool) { rewinding.store(on, ordering: .relaxed) }
    func setRewindEnabled(_ on: Bool) { rewindEnabled.store(on, ordering: .relaxed) }

    func start() {
        guard thread == nil else { return }
        running.store(true, ordering: .relaxed)
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "emulation"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        guard thread != nil else { return }
        running.store(false, ordering: .relaxed)
        // Wait for the emulation thread to finish its current frame and exit BEFORE the core can be
        // deallocated — otherwise it runs frames on freed memory (use-after-free). Bounded: the loop
        // re-checks `running` every iteration (≤ a frame / 500µs).
        _ = didStop.wait(timeout: .now() + 2)
        thread = nil
    }

    // MARK: - Persistence (runs on the emulation thread, blocks the caller briefly)

    /// Enqueue work to run on the emulation thread with exclusive access to the core.
    private func perform(_ work: @escaping (EmulatorCore) -> Void) {
        cmdLock.lock(); commands.append(work); cmdLock.unlock()
    }

    /// Serialize full machine state (save state / suspend).
    func saveState() -> Data? {
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        perform { core in out = try? core.saveState(); sem.signal() }
        sem.wait()
        return out
    }

    /// Restore a previously saved machine state.
    @discardableResult
    func loadState(_ data: Data) -> Bool {
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        perform { core in
            do { try core.loadState(data); ok = true } catch { ok = false }
            sem.signal()
        }
        sem.wait()
        return ok
    }

    /// Clone the persistent cartridge save (battery/SRAM), or nil if the game has none.
    func cloneSaveData() -> Data? {
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        perform { core in out = core.saveData; sem.signal() }
        sem.wait()
        return out
    }

    /// Copy the most recently produced frame for display (called on the main/render thread).
    func copyLatestFrame(into dst: UnsafeMutablePointer<UInt32>) {
        frameLock.lock()
        latestFrame.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: $0.count) }
        frameLock.unlock()
    }

    private func runLoop() {
        let oneFrameSlots = (sampleRate / 60) * 2   // ~one video-frame of audio, in slots
        defer { didStop.signal() }   // let stop() know the thread has fully exited

        while running.load(ordering: .relaxed) {
            // Process pending save/load commands first, so they run even while audio-paced.
            cmdLock.lock()
            let batch = commands
            commands.removeAll(keepingCapacity: true)
            cmdLock.unlock()
            for command in batch { command(core) }

            // Paused: hold the current frame and let the audio ring drain to silence. Commands (save/
            // load) still run above, so state actions work while paused.
            if paused.load(ordering: .relaxed) {
                usleep(16000)
                continue
            }

            // Rewind: replay recent snapshots backward, ~60Hz, audio muted. Skipped when the
            // Rewind setting is off (no history is being captured, so there's nothing to replay).
            if rewinding.load(ordering: .relaxed) && rewindEnabled.load(ordering: .relaxed) {
                if let snapshot = rewindStates.popLast() {
                    try? core.loadState(snapshot)
                    core.runFrame()
                    publishVideo()
                }
                usleep(16000)
                continue
            }

            let ff = fastForward.load(ordering: .relaxed)
            let mult = Double(speedMilli.load(ordering: .relaxed)) / 1000.0
            let turbo = ff || mult > 1.0

            // Real-time pacing comes from audio backpressure; skipped for turbo (a held fast-forward
            // runs uncapped, a finite speed multiplier is video-timed below).
            if !turbo && ring.freeToWrite < oneFrameSlots + 64 {
                usleep(500)
                continue
            }

            let frameStart = (mult > 1.0 && !ff) ? DispatchTime.now().uptimeNanoseconds : 0

            var held = kbButtons.load(ordering: .relaxed)
                | padButtons.load(ordering: .relaxed)
                | touchButtons.load(ordering: .relaxed)
            if swapAB.load(ordering: .relaxed) {
                let a = held & GBAButtons.a.rawValue, b = held & GBAButtons.b.rawValue
                held &= ~(GBAButtons.a.rawValue | GBAButtons.b.rawValue)
                if a != 0 { held |= GBAButtons.b.rawValue }
                if b != 0 { held |= GBAButtons.a.rawValue }
            }
            core.setButtons(GBAButtons(rawValue: held))
            core.runFrame()
            publishVideo()
            captureRewindSnapshot()

            drainAudio(discard: turbo)   // audio is muted while turbo / fast-forwarding

            // A finite speed multiplier (1.5× / 2×) is clocked to 60·mult fps here.
            if mult > 1.0 && !ff {
                let target = UInt64(1_000_000_000.0 / (60.0 * mult))
                let elapsed = DispatchTime.now().uptimeNanoseconds - frameStart
                if elapsed < target { usleep(UInt32((target - elapsed) / 1000)) }
            }
        }
    }

    /// Fill the producer buffer from the core and swap it in for the renderer (O(1) swap).
    private func publishVideo() {
        producerFrame.withUnsafeMutableBufferPointer { core.copyVideo(into: $0.baseAddress!) }
        frameLock.lock()
        swap(&latestFrame, &producerFrame)
        frameLock.unlock()
    }

    /// Drain the core's audio for this frame, either into the ring or discarded (fast-forward).
    private func drainAudio(discard: Bool) {
        let scratchFrames = audioScratch.count / 2
        while true {
            let got = audioScratch.withUnsafeMutableBufferPointer {
                core.readAudio(into: $0.baseAddress!, maxFrames: scratchFrames)
            }
            if got <= 0 { break }
            if !discard {
                audioScratch.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: got * 2) }
            }
            if got < scratchFrames { break }
        }
    }

    /// Snapshot machine state every `rewindInterval` frames for the rewind buffer.
    private func captureRewindSnapshot() {
        guard rewindEnabled.load(ordering: .relaxed) else { return }
        frameCounter += 1
        guard frameCounter % rewindInterval == 0, let state = try? core.saveState() else { return }
        rewindStates.append(state)
        if rewindStates.count > rewindMax { rewindStates.removeFirst() }
    }
}
