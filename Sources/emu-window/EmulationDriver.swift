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
    /// The loaded content's true refresh rate (≈50 Hz PAL / 59.94 NTSC for PS1; fixed for handhelds).
    /// "% of full speed" is measured against this so a native-50 Hz PAL game reads 100%, not 83%.
    let refreshRate: Double
    let ring: AudioRingBuffer

    private let core: EmulatorCore
    private let kbButtons = Atomic<UInt16>(0)       // keyboard → GBA-key subset
    private let touchButtons = Atomic<UInt16>(0)    // on-screen clickable controls → GBA-key subset
    private let padButtons = Atomic<UInt32>(0)      // physical controller → full PadButtons
    private let padAnalog = Atomic<UInt64>(0)       // physical controller sticks, packed 4×Int16
    private let lightLevel = Atomic<UInt8>(0)      // solar-sensor light (0 dark … 255 full sun)
    let hasLightSensor: Bool                       // this cart has a Boktai-style photodiode
    let discCount: Int                             // multi-disc PS1 games; 0/1 = single-disc
    private let currentDisc = Atomic<Int>(0)       // which disc is inserted (tracked frontend-side)
    private let running = Atomic<Bool>(false)
    private let paused = Atomic<Bool>(false)
    private let fastForward = Atomic<Bool>(false)
    private let speedMilli = Atomic<Int>(1000)   // playback speed ×1000 (1000 = 1×, 1500 = 1.5×, …)
    private let swapAB = Atomic<Bool>(false)      // swap the A/B buttons in the input merge
    private let rewinding = Atomic<Bool>(false)
    private let rewindEnabled = Atomic<Bool>(true)   // off = no history captured (saves CPU/memory)
    private let runAhead = Atomic<Int>(0)            // 0 = off; N = display N frames ahead to cut input lag
    private let framesRun = Atomic<Int>(0)           // total frames the core has advanced (for the stats overlay)

    // Rewind: a bounded ring of recent save states, captured on the emulation thread.
    private var rewindStates: [Data] = []
    private let rewindInterval = 6      // snapshot every N frames (~10 snapshots/sec)
    private let rewindMax = 150         // ~15s of history
    private var frameCounter = 0

    private let frameLock = NSLock()
    private var latestFrame: [UInt32]
    private var producerFrame: [UInt32]
    private var audioScratch: [Int16]
    // The live frame's dimensions. `width`/`height` above are the maximum the core can emit (and the
    // buffer allocation); these track the size of the actual frame published this iteration, which the
    // PS1 changes per-frame. Guarded by `frameLock` alongside the pixel buffers.
    private var latestW: Int
    private var latestH: Int
    private var producerW: Int
    private var producerH: Int

    // Commands run on the emulation thread so the core stays single-threaded (save/load state,
    // battery clone/restore). Drained at the top of every loop iteration.
    private let cmdLock = NSLock()
    private var commands: [(EmulatorCore) -> Void] = []

    private var thread: Thread?
    private let didStop = DispatchSemaphore(value: 0)   // signaled when runLoop actually exits

    init(core: EmulatorCore) {
        self.core = core
        hasLightSensor = core.hasLightSensor
        discCount = core.discCount
        // Size every frame buffer to the core's *maximum* frame, not the current one — the PS1 grows
        // its frame with the internal-resolution upscale, and a buffer sized to a smaller frame would
        // overrun once the core emits a bigger one.
        (width, height) = core.maxVideoSize
        sampleRate = core.audioSampleRate
        refreshRate = core.nominalRefreshRate
        latestFrame = [UInt32](repeating: 0, count: width * height)
        producerFrame = [UInt32](repeating: 0, count: width * height)
        latestW = width; latestH = height
        producerW = width; producerH = height
        ring = AudioRingBuffer(frameCapacity: 8192)          // ~250ms headroom at 32.7kHz
        audioScratch = [Int16](repeating: 0, count: 4096)    // 2048 stereo frames of scratch
    }

    // Input (thread-safe; called from main). Keyboard, pad and on-screen touch are OR-merged. The
    // keyboard and on-screen controls speak the GBA-key subset; the physical controller supplies the
    // full pad (all buttons + analog sticks) for systems that use them.
    func setKeyboard(_ b: GBAButtons) { kbButtons.store(b.rawValue, ordering: .relaxed) }
    func setTouch(_ b: GBAButtons) { touchButtons.store(b.rawValue, ordering: .relaxed) }
    func setPad(_ buttons: PadButtons,
                leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0) {
        padButtons.store(buttons.rawValue, ordering: .relaxed)
        padAnalog.store(Self.packAnalog(leftX, leftY, rightX, rightY), ordering: .relaxed)
    }
    /// Set the simulated solar-sensor light level (0 = dark … 255 = full sun), applied each frame.
    func setLuminance(_ v: UInt8) { lightLevel.store(v, ordering: .relaxed) }

    /// Currently-inserted disc (0-based) for a multi-disc game.
    var currentDiscIndex: Int { currentDisc.load(ordering: .relaxed) }
    /// Swap to disc `index` on the emulation thread (eject → insert), then remember it.
    func setDisc(_ index: Int) {
        perform { core in core.setDisc(index) }
        currentDisc.store(index, ordering: .relaxed)
    }

    // Pack/unpack four Int16 stick axes into one atomic word so the sticks update lock-free with the
    // pad buttons. Bit-reinterpret (not sign-extend) each axis into its 16-bit lane.
    static func packAnalog(_ lx: Int16, _ ly: Int16, _ rx: Int16, _ ry: Int16) -> UInt64 {
        UInt64(UInt16(bitPattern: lx))
            | (UInt64(UInt16(bitPattern: ly)) << 16)
            | (UInt64(UInt16(bitPattern: rx)) << 32)
            | (UInt64(UInt16(bitPattern: ry)) << 48)
    }
    static func unpackAnalog(_ v: UInt64) -> (Int16, Int16, Int16, Int16) {
        (Int16(bitPattern: UInt16(truncatingIfNeeded: v)),
         Int16(bitPattern: UInt16(truncatingIfNeeded: v >> 16)),
         Int16(bitPattern: UInt16(truncatingIfNeeded: v >> 32)),
         Int16(bitPattern: UInt16(truncatingIfNeeded: v >> 48)))
    }

    func setPaused(_ on: Bool) { paused.store(on, ordering: .relaxed) }
    var isPaused: Bool { paused.load(ordering: .relaxed) }
    func setFastForward(_ on: Bool) { fastForward.store(on, ordering: .relaxed) }
    /// A finite playback speed (1.0 = real time, 1.5, 2.0…). Video-timed, audio muted above 1×.
    func setSpeed(_ multiplier: Double) { speedMilli.store(Int(multiplier * 1000), ordering: .relaxed) }
    func setSwapAB(_ on: Bool) { swapAB.store(on, ordering: .relaxed) }
    func setRewinding(_ on: Bool) { rewinding.store(on, ordering: .relaxed) }
    func setRewindEnabled(_ on: Bool) { rewindEnabled.store(on, ordering: .relaxed) }
    /// Frames of run-ahead (0 = off). Displays a future frame so input appears sooner — at the cost of
    /// running `frames` extra frames + one state save/restore per displayed frame. Kept ≤ 2.
    func setRunAhead(_ frames: Int) { runAhead.store(max(0, min(2, frames)), ordering: .relaxed) }

    /// Total frames the core has advanced since launch. Sampled over time by the stats overlay to
    /// derive the live emulation frame rate (and, from it, the % of full speed).
    var framesRunCount: Int { framesRun.load(ordering: .relaxed) }

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

    /// Copy the most recently produced frame for display (called on the main/render thread) and
    /// report its dimensions. Writes at most `capacity` pixels, so an oversized frame is truncated
    /// rather than overrunning `dst`; size `dst` to `width * height` (the max) for a complete frame.
    @discardableResult
    func copyLatestFrame(into dst: UnsafeMutablePointer<UInt32>, capacity: Int) -> (width: Int, height: Int) {
        frameLock.lock()
        let (w, h) = (latestW, latestH)
        latestFrame.withUnsafeBufferPointer {
            dst.update(from: $0.baseAddress!, count: min(w * h, min(capacity, $0.count)))
        }
        frameLock.unlock()
        return (w, h)
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
                    countFrame()
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

            if hasLightSensor { core.setLuminance(lightLevel.load(ordering: .relaxed)) }

            // Merge the three input sources into one system-agnostic snapshot: keyboard + touch
            // (GBA-key subsets) unioned with the full physical-controller pad and its sticks.
            let kbTouch = kbButtons.load(ordering: .relaxed) | touchButtons.load(ordering: .relaxed)
            var buttons = PadButtons(gba: GBAButtons(rawValue: kbTouch))
            buttons.formUnion(PadButtons(rawValue: padButtons.load(ordering: .relaxed)))
            if swapAB.load(ordering: .relaxed) {
                let s = buttons.contains(.south), e = buttons.contains(.east)
                buttons.remove([.south, .east])
                if s { buttons.insert(.east) }
                if e { buttons.insert(.south) }
            }
            let (lx, ly, rx, ry) = Self.unpackAnalog(padAnalog.load(ordering: .relaxed))
            let input = PadInput(buttons: buttons, leftX: lx, leftY: ly, rightX: rx, rightY: ry)
            let ahead = runAhead.load(ordering: .relaxed)
            if ahead > 0 && !turbo {
                // Run-ahead: commit one real frame (with audio), then run `ahead` more frames to
                // display a future frame — so a button press shows up `ahead` frames sooner. The
                // committed timeline is checkpointed and restored, so it still advances exactly one
                // frame per iteration (audio pacing and rewind stay on the real timeline).
                core.setInput(input)
                core.runFrame()
                countFrame()
                drainAudio(discard: false)              // the real frame's audio → the ring
                if let checkpoint = try? core.saveState() {
                    for _ in 0..<ahead {
                        core.setInput(input)
                        core.runFrame()
                        drainAudio(discard: true)        // future frames' audio is thrown away
                    }
                    publishVideo()                       // show the frame `ahead` into the future
                    try? core.loadState(checkpoint)      // rewind the core to the committed state
                } else {
                    publishVideo()                       // save failed — just show the real frame
                }
                captureRewindSnapshot()
            } else {
                core.setInput(input)
                core.runFrame()
                countFrame()
                publishVideo()
                captureRewindSnapshot()
                drainAudio(discard: turbo)   // audio is muted while turbo / fast-forwarding
            }

            // A finite speed multiplier (1.5× / 2×) is clocked to 60·mult fps here.
            if mult > 1.0 && !ff {
                let target = UInt64(1_000_000_000.0 / (60.0 * mult))
                let elapsed = DispatchTime.now().uptimeNanoseconds - frameStart
                if elapsed < target { usleep(UInt32((target - elapsed) / 1000)) }
            }
        }
    }

    /// Bump the run-frame counter (emulation thread only — single writer, so a plain load/store is
    /// enough; the stats overlay reads it from the main thread).
    private func countFrame() {
        framesRun.store(framesRun.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
    }

    /// Fill the producer buffer from the core and swap it in for the renderer (O(1) swap). Also
    /// captures the frame's live dimensions (the PS1 changes them per frame), clamped to the buffer
    /// so a larger-than-max report can never overrun the swap.
    private func publishVideo() {
        producerFrame.withUnsafeMutableBufferPointer {
            core.copyVideo(into: $0.baseAddress!, capacity: $0.count)
        }
        let (w, h) = core.videoSize
        producerW = min(max(w, 0), width)
        producerH = min(max(h, 0), height)
        frameLock.lock()
        swap(&latestFrame, &producerFrame)
        swap(&latestW, &producerW)
        swap(&latestH, &producerH)
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
