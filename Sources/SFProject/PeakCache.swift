import Foundation
import SFCore

/// Multi-resolution waveform overview (min/max pairs, mono-summed) used to draw clips quickly.
/// Level 0 holds one min/max pair per `baseBlock` samples; each further level halves the
/// resolution. Peaks are computed once in the background and cached as a small binary file in
/// the project's Peaks/ folder, so opening a project never needs to decode all audio up front.
public final class WaveformPeaks: @unchecked Sendable {
    public static let baseBlock = 256
    public let sampleRate: Double
    public let frameCount: Int
    /// levels[l] = interleaved [min0, max0, min1, max1, ...]; block size = baseBlock << l
    public let levels: [[Float]]

    public init(sampleRate: Double, frameCount: Int, levels: [[Float]]) {
        self.sampleRate = sampleRate; self.frameCount = frameCount; self.levels = levels
    }

    public convenience init(audio: AudioData) {
        let mono = audio.mono
        let block = WaveformPeaks.baseBlock
        let n = (mono.count + block - 1) / block
        var level0 = [Float](repeating: 0, count: n * 2)
        mono.withUnsafeBufferPointer { src in
            for b in 0..<n {
                let s = b * block, e = Swift.min(mono.count, s + block)
                var lo: Float = 0, hi: Float = 0
                for i in s..<e { let v = src[i]; if v < lo { lo = v }; if v > hi { hi = v } }
                level0[2 * b] = lo; level0[2 * b + 1] = hi
            }
        }
        var levels = [level0]
        while let last = levels.last, last.count > 2 * 64 {
            let pairs = last.count / 2
            let m = (pairs + 1) / 2
            var next = [Float](repeating: 0, count: m * 2)
            for i in 0..<m {
                let a = 2 * i, b = Swift.min(pairs - 1, 2 * i + 1)
                next[2 * i] = Swift.min(last[2 * a], last[2 * b])
                next[2 * i + 1] = Swift.max(last[2 * a + 1], last[2 * b + 1])
            }
            levels.append(next)
        }
        self.init(sampleRate: audio.sampleRate, frameCount: audio.frameCount, levels: levels)
    }

    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// Returns `columns` min/max pairs covering [startSec, startSec+lengthSec) of the source,
    /// picking the coarsest level that still has at least one block per column.
    public func columns(start startSec: Double, length lengthSec: Double, columns: Int) -> [(min: Float, max: Float)] {
        guard columns > 0, lengthSec > 0, !levels.isEmpty else { return [] }
        let samplesPerColumn = lengthSec * sampleRate / Double(columns)
        var level = 0
        while level + 1 < levels.count, Double(WaveformPeaks.baseBlock << (level + 1)) <= samplesPerColumn { level += 1 }
        let data = levels[level]
        let blockSize = Double(WaveformPeaks.baseBlock << level)
        let pairs = data.count / 2
        var out = [(min: Float, max: Float)](repeating: (0, 0), count: columns)
        for c in 0..<columns {
            let s0 = (startSec * sampleRate + Double(c) * samplesPerColumn) / blockSize
            let s1 = (startSec * sampleRate + Double(c + 1) * samplesPerColumn) / blockSize
            var b0 = Int(s0.rounded(.down)), b1 = Swift.max(b0 + 1, Int(s1.rounded(.up)))
            b0 = Swift.max(0, b0); b1 = Swift.min(pairs, b1)
            guard b0 < b1 else { continue }
            var lo: Float = 0, hi: Float = 0
            for b in b0..<b1 { lo = Swift.min(lo, data[2 * b]); hi = Swift.max(hi, data[2 * b + 1]) }
            out[c] = (lo, hi)
        }
        return out
    }

    // MARK: Binary cache format: "SFPK" | u32 version | f64 sr | u64 frames | u32 levels | (u32 count, f32*count)*

    public func encoded() -> Data {
        var d = Data("SFPK".utf8)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(UInt32(1).littleEndian); put(sampleRate.bitPattern.littleEndian); put(UInt64(frameCount).littleEndian)
        put(UInt32(levels.count).littleEndian)
        for l in levels {
            put(UInt32(l.count).littleEndian)
            for v in l { put(v.bitPattern.littleEndian) }
        }
        return d
    }

    public static func decode(_ data: Data) -> WaveformPeaks? {
        let bytes = [UInt8](data)
        guard bytes.count >= 28, bytes[0..<4] == [0x53, 0x46, 0x50, 0x4B] else { return nil }
        var pos = 4
        func u32() -> UInt32? {
            guard pos + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(bytes[pos + i]) << (8 * UInt32(i)) }
            pos += 4; return v
        }
        func u64() -> UInt64? {
            guard pos + 8 <= bytes.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
            pos += 8; return v
        }
        guard u32() == 1, let srBits = u64(), let frames = u64(), let nLevels = u32(), nLevels < 64 else { return nil }
        var levels: [[Float]] = []
        for _ in 0..<nLevels {
            guard let count = u32(), pos + Int(count) * 4 <= bytes.count else { return nil }
            var l = [Float](repeating: 0, count: Int(count))
            for i in 0..<Int(count) { l[i] = Float(bitPattern: u32()!) }
            levels.append(l)
        }
        return WaveformPeaks(sampleRate: Double(bitPattern: srBits), frameCount: Int(frames), levels: levels)
    }
}

/// Loads/creates waveform peaks for audio files, caching in memory and on disk.
public final class PeakCache: @unchecked Sendable {
    public static let shared = PeakCache()
    private let lock = NSLock()
    private var memory: [String: WaveformPeaks] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "studioforge.peaks", qos: .utility, attributes: .concurrent)

    public init() {}

    /// Cache file for an audio file: inside `peaksFolder` if given, else Application Support/Peaks.
    public static func cacheURL(for audio: URL, peaksFolder: URL?) -> URL {
        let folder = peaksFolder ?? AppPaths.sub("PeakCache")
        let attrs = try? FileManager.default.attributesOfItem(atPath: audio.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int64(((attrs?[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970)
        // Stable, readable key: file name + size + mtime (invalidates when the file changes).
        let key = "\(audio.lastPathComponent)-\(size)-\(mtime).sfpk"
        return folder.appendingPathComponent(key)
    }

    /// Returns cached peaks immediately if available in memory.
    public func cached(_ url: URL) -> WaveformPeaks? {
        lock.lock(); defer { lock.unlock() }
        return memory[url.standardizedFileURL.path]
    }

    /// Synchronous load (disk cache or compute). Call off the main thread.
    public func load(_ url: URL, peaksFolder: URL?) throws -> WaveformPeaks {
        let key = url.standardizedFileURL.path
        if let p = cached(url) { return p }
        let cacheFile = PeakCache.cacheURL(for: url, peaksFolder: peaksFolder)
        if let data = try? Data(contentsOf: cacheFile), let p = WaveformPeaks.decode(data) {
            lock.lock(); memory[key] = p; lock.unlock()
            return p
        }
        let audio = try AudioDecoding.decode(url)
        let peaks = WaveformPeaks(audio: audio)
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? peaks.encoded().write(to: cacheFile, options: .atomic)
        lock.lock(); memory[key] = peaks; lock.unlock()
        return peaks
    }

    /// Asynchronous load; completion runs on the main queue. Duplicate requests are coalesced.
    public func request(_ url: URL, peaksFolder: URL?, completion: @escaping (WaveformPeaks?) -> Void) {
        if let p = cached(url) { completion(p); return }
        let key = url.standardizedFileURL.path
        lock.lock()
        let already = inFlight.contains(key)
        inFlight.insert(key)
        lock.unlock()
        if already { return }
        queue.async {
            let p = try? self.load(url, peaksFolder: peaksFolder)
            self.lock.lock(); self.inFlight.remove(key); self.lock.unlock()
            DispatchQueue.main.async { completion(p) }
        }
    }

    public func invalidate(_ url: URL) {
        lock.lock(); memory[url.standardizedFileURL.path] = nil; lock.unlock()
    }
}
