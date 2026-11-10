import Foundation
import SFCore

/// Immutable, pre-allocated sample storage that the audio thread reads without locks or ARC
/// traffic on array buffers. Mono files share one buffer for both sides.
public final class SampleBuffer: @unchecked Sendable {
    public let frames: Int
    public let channels: Int
    public let left: UnsafeMutablePointer<Float>
    public let right: UnsafeMutablePointer<Float>
    public let sampleRate: Double

    public init(audio: AudioData) {
        let n = audio.frameCount
        frames = n
        channels = max(1, min(2, audio.channelCount))
        sampleRate = audio.sampleRate
        func copy(_ c: [Float]) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, n))
            p.initialize(repeating: 0, count: max(1, n))
            c.withUnsafeBufferPointer { if let b = $0.baseAddress { p.update(from: b, count: min(n, c.count)) } }
            return p
        }
        let l = copy(audio.channels.first ?? [])
        left = l
        right = audio.channelCount >= 2 ? copy(audio.channels[1]) : l
    }

    deinit {
        if right != left { right.deallocate() }
        left.deallocate()
    }
}

/// Lazily decodes clip audio (resampled to the engine rate) on a background queue and keeps it in
/// memory. The render graph only references buffers that are already loaded; when a load
/// completes `onLoaded` fires on the main queue so the controller can rebuild the graph.
///
/// Baseline note: whole files are held in RAM (float32). Disk streaming for very long projects is
/// listed as future work in docs/ARCHITECTURE.md.
public final class ClipAudioCache: @unchecked Sendable {
    public private(set) var sampleRate: Double
    private let lock = NSLock()
    private var buffers: [String: SampleBuffer] = [:]
    private var loading: Set<String> = []
    public private(set) var failures: [String: String] = [:]
    private let queue = DispatchQueue(label: "studioforge.clipcache", qos: .userInitiated, attributes: .concurrent)
    public var onLoaded: (() -> Void)?

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public func setSampleRate(_ sr: Double) {
        lock.lock(); defer { lock.unlock() }
        guard sr != sampleRate else { return }
        sampleRate = sr
        buffers.removeAll()
        failures.removeAll()
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Returns the buffer if loaded; otherwise schedules a background load and returns nil.
    public func buffer(for url: URL) -> SampleBuffer? {
        let k = Self.key(url)
        lock.lock()
        if let b = buffers[k] { lock.unlock(); return b }
        if loading.contains(k) || failures[k] != nil { lock.unlock(); return nil }
        loading.insert(k)
        let sr = sampleRate
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Self.decode(url, sampleRate: sr) }
            self.lock.lock()
            self.loading.remove(k)
            let stillValid = self.sampleRate == sr
            switch result {
            case .success(let b): if stillValid { self.buffers[k] = b }
            case .failure(let e): self.failures[k] = e.localizedDescription
            }
            self.lock.unlock()
            DispatchQueue.main.async { self.onLoaded?() }
        }
        return nil
    }

    /// Synchronous load (offline rendering, tests).
    public func loadSync(_ url: URL) throws -> SampleBuffer {
        let k = Self.key(url)
        lock.lock()
        if let b = buffers[k] { lock.unlock(); return b }
        let sr = sampleRate
        lock.unlock()
        let b = try Self.decode(url, sampleRate: sr)
        lock.lock(); buffers[k] = b; lock.unlock()
        return b
    }

    /// Inserts already-decoded audio (e.g. a just-finished recording) to avoid re-reading it.
    public func insert(_ audio: AudioData, for url: URL) {
        let a = audio.sampleRate == sampleRate ? audio : Resampler.resample(audio, to: sampleRate)
        lock.lock(); buffers[Self.key(url)] = SampleBuffer(audio: a); failures[Self.key(url)] = nil; lock.unlock()
    }

    public func isLoading(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return loading.contains(Self.key(url)) }
    public func failure(for url: URL) -> String? { lock.lock(); defer { lock.unlock() }; return failures[Self.key(url)] }

    public func retryFailed() { lock.lock(); failures.removeAll(); lock.unlock() }

    /// Drops buffers no longer referenced by the project (old graphs keep their own references
    /// alive until the audio thread has let go of them).
    public func purge(keeping urls: Set<URL>) {
        let keep = Set(urls.map(Self.key))
        lock.lock(); buffers = buffers.filter { keep.contains($0.key) }; lock.unlock()
    }

    public var memoryBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return buffers.values.reduce(0) { $0 + $1.frames * $1.channels * 4 }
    }

    static func decode(_ url: URL, sampleRate: Double) throws -> SampleBuffer {
        var audio = try AudioDecoding.decode(url)
        if audio.sampleRate != sampleRate { audio = Resampler.resample(audio, to: sampleRate) }
        return SampleBuffer(audio: audio)
    }
}
