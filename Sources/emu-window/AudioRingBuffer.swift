import Synchronization

/// Lock-free single-producer/single-consumer ring of interleaved Int16 samples.
/// The emulation thread writes; the real-time audio thread reads. Counts are in Int16 *slots*
/// (a stereo sample-frame is 2 slots). Capacity is rounded up to a power of two.
final class AudioRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutableBufferPointer<Int16>
    private let capacity: Int
    private let mask: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    /// - Parameter frameCapacity: capacity in stereo sample-frames.
    init(frameCapacity: Int) {
        var slots = 1
        while slots < frameCapacity * 2 { slots <<= 1 }
        capacity = slots
        mask = slots - 1
        buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: slots)
        buffer.initialize(repeating: 0)
    }

    deinit { buffer.deallocate() }

    var availableToRead: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed)
    }

    var freeToWrite: Int { capacity - availableToRead }

    /// Producer side. Returns the number of slots actually written.
    @discardableResult
    func write(_ src: UnsafePointer<Int16>, count: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacity - (w - r)
        let n = min(count, free)
        var i = 0
        while i < n { buffer[(w &+ i) & mask] = src[i]; i += 1 }
        writeIndex.store(w &+ n, ordering: .releasing)
        return n
    }

    /// Consumer side. Returns the number of slots actually read.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Int16>, count: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let avail = w - r
        let n = min(count, avail)
        var i = 0
        while i < n { dst[i] = buffer[(r &+ i) & mask]; i += 1 }
        readIndex.store(r &+ n, ordering: .releasing)
        return n
    }
}
