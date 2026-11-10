import Foundation
import Atomics

// MARK: - Lock-free primitives used to communicate with the real-time audio thread.
// Rule of thumb in StudioForge: the audio thread never allocates, never locks, never does I/O.
// Everything it needs is pre-allocated on the main thread and published through these types.

/// A Float that can be written from the UI thread and read from the audio thread without locks.
public final class AtomicFloat: @unchecked Sendable {
    private let storage: ManagedAtomic<UInt32>
    public init(_ value: Float = 0) { storage = ManagedAtomic(value.bitPattern) }
    @inline(__always) public var value: Float {
        get { Float(bitPattern: storage.load(ordering: .relaxed)) }
        set { storage.store(newValue.bitPattern, ordering: .relaxed) }
    }
    /// Stores `max(current, v)` (used for peak meters; the reader resets with `exchange`).
    @inline(__always) public func storeMax(_ v: Float) {
        var current = storage.load(ordering: .relaxed)
        while Float(bitPattern: current) < v {
            let (exchanged, original) = storage.weakCompareExchange(expected: current, desired: v.bitPattern, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }
    @inline(__always) public func exchange(_ v: Float) -> Float {
        Float(bitPattern: storage.exchange(v.bitPattern, ordering: .relaxed))
    }
}

/// Atomic Double (positions, tempo).
public final class AtomicDouble: @unchecked Sendable {
    private let storage: ManagedAtomic<UInt64>
    public init(_ value: Double = 0) { storage = ManagedAtomic(value.bitPattern) }
    @inline(__always) public var value: Double {
        get { Double(bitPattern: storage.load(ordering: .relaxed)) }
        set { storage.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

public final class AtomicBool: @unchecked Sendable {
    private let storage: ManagedAtomic<Bool>
    public init(_ value: Bool = false) { storage = ManagedAtomic(value) }
    @inline(__always) public var value: Bool {
        get { storage.load(ordering: .relaxed) }
        set { storage.store(newValue, ordering: .relaxed) }
    }
    @inline(__always) public func exchange(_ v: Bool) -> Bool { storage.exchange(v, ordering: .acquiringAndReleasing) }
}

public final class AtomicInt: @unchecked Sendable {
    private let storage: ManagedAtomic<Int>
    public init(_ value: Int = 0) { storage = ManagedAtomic(value) }
    @inline(__always) public var value: Int {
        get { storage.load(ordering: .acquiring) }
        set { storage.store(newValue, ordering: .releasing) }
    }
    @inline(__always) public func exchange(_ v: Int) -> Int { storage.exchange(v, ordering: .acquiringAndReleasing) }
    @inline(__always) public func add(_ v: Int) { storage.wrappingIncrement(by: v, ordering: .relaxed) }
}

// MARK: - SPSC ring buffer

/// Single-producer / single-consumer lock-free FIFO of Float samples.
/// Used audio-thread -> disk-writer (recording) and MIDI-thread -> audio-thread (via `SPSCQueue`).
public final class SPSCRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let writeIndex = ManagedAtomic<Int>(0)
    private let readIndex = ManagedAtomic<Int>(0)

    public init(minimumCapacity: Int) {
        var cap = 1
        while cap < max(2, minimumCapacity) { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        buffer = .allocate(capacity: cap)
        buffer.initialize(repeating: 0, count: cap)
    }
    deinit { buffer.deallocate() }

    public var availableToRead: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed) }
    public var availableToWrite: Int { capacity - (writeIndex.load(ordering: .relaxed) - readIndex.load(ordering: .acquiring)) }

    /// Producer side. Returns number of samples actually written (drops on overflow, never blocks).
    @discardableResult
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let n = min(count, capacity - (w - r))
        if n <= 0 { return 0 }
        let start = w & mask
        let first = min(n, capacity - start)
        (buffer + start).update(from: src, count: first)
        if n > first { buffer.update(from: src + first, count: n - first) }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Producer side: writes `count` frames interleaved as L,R,L,R...
    @discardableResult
    public func writeInterleaved(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let frames = min(count, (capacity - (w - r)) / 2)
        if frames <= 0 { return 0 }
        var idx = w
        for i in 0..<frames {
            buffer[idx & mask] = left[i]; idx += 1
            buffer[idx & mask] = right[i]; idx += 1
        }
        writeIndex.store(idx, ordering: .releasing)
        return frames
    }

    /// Consumer side.
    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(count, w - r)
        if n <= 0 { return 0 }
        let start = r & mask
        let first = min(n, capacity - start)
        dst.update(from: buffer + start, count: first)
        if n > first { (dst + first).update(from: buffer, count: n - first) }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }

    public func reset() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}

/// Fixed-capacity lock-free SPSC queue of small POD events (e.g. MIDI messages).
public final class SPSCQueue<Element>: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Element>
    private let writeIndex = ManagedAtomic<Int>(0)
    private let readIndex = ManagedAtomic<Int>(0)

    public init(capacity minimum: Int, filler: Element) {
        var cap = 2
        while cap < minimum { cap <<= 1 }
        capacity = cap; mask = cap - 1
        storage = .allocate(capacity: cap)
        storage.initialize(repeating: filler, count: cap)
    }
    deinit { storage.deinitialize(count: capacity); storage.deallocate() }

    @discardableResult public func push(_ e: Element) -> Bool {
        let w = writeIndex.load(ordering: .relaxed)
        if w - readIndex.load(ordering: .acquiring) >= capacity { return false }
        storage[w & mask] = e
        writeIndex.store(w + 1, ordering: .releasing)
        return true
    }
    public func pop() -> Element? {
        let r = readIndex.load(ordering: .relaxed)
        if r == writeIndex.load(ordering: .acquiring) { return nil }
        let e = storage[r & mask]
        readIndex.store(r + 1, ordering: .releasing)
        return e
    }
}

// MARK: - Real-time safe object hand-over

/// Publishes immutable/pre-allocated objects from the main thread to the audio thread.
/// The audio thread never releases the last reference to an object (no deallocation on the
/// audio thread): replaced objects are parked in a lock-free "retired" list that the main
/// thread drains in `collectGarbage()` / on the next `publish`.
public final class RTObjectSwap<T: AnyObject>: @unchecked Sendable {
    private let pending = ManagedAtomic<UInt>(0)
    private var active: Unmanaged<T>?              // audio thread only
    private let retired: [ManagedAtomic<UInt>] = (0..<32).map { _ in ManagedAtomic<UInt>(0) }
    private let lock = NSLock()
    private var lastPublished: T?                  // main-thread mirror of what the audio side will use

    public init() {}

    /// Main thread.
    public func publish(_ object: T) {
        lock.lock(); defer { lock.unlock() }
        collectGarbageLocked()
        let bits = UInt(bitPattern: Unmanaged.passRetained(object).toOpaque())
        let old = pending.exchange(bits, ordering: .acquiringAndReleasing)
        if old != 0, let ptr = UnsafeRawPointer(bitPattern: old) {
            Unmanaged<T>.fromOpaque(ptr).release()   // never picked up by the audio thread
        }
        lastPublished = object
    }

    /// Main thread: most recently published object.
    public var latest: T? { lock.lock(); defer { lock.unlock() }; return lastPublished }

    /// Audio thread: returns the current object (picking up a newly published one if any).
    @inline(__always) public func acquire() -> T? {
        let bits = pending.exchange(0, ordering: .acquiringAndReleasing)
        if bits != 0, let ptr = UnsafeRawPointer(bitPattern: bits) {
            if let old = active { retire(old) }
            active = Unmanaged<T>.fromOpaque(ptr)
        }
        return active?.takeUnretainedValue()
    }

    private func retire(_ u: Unmanaged<T>) {
        let bits = UInt(bitPattern: u.toOpaque())
        for slot in retired {
            if slot.compareExchange(expected: 0, desired: bits, ordering: .acquiringAndReleasing).exchanged { return }
        }
        // All slots full (main thread stalled for a long time): leak rather than free on audio thread.
    }

    /// Main thread: release objects the audio thread no longer uses.
    public func collectGarbage() { lock.lock(); collectGarbageLocked(); lock.unlock() }

    private func collectGarbageLocked() {
        for slot in retired {
            let bits = slot.exchange(0, ordering: .acquiringAndReleasing)
            if bits != 0, let ptr = UnsafeRawPointer(bitPattern: bits) { Unmanaged<T>.fromOpaque(ptr).release() }
        }
    }
}

/// Host information shared with effects (tempo for synced delays/LFOs).
public final class HostContext: @unchecked Sendable {
    public static let shared = HostContext()
    public let tempo = AtomicDouble(120)
    public let isPlaying = AtomicBool(false)
}
