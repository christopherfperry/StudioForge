import Foundation
import SFCore

/// I/O contract between `tools/convert_htdemucs_core.py` and the app (Demucs v4 htdemucs_6s with
/// the STFT moved out of the network).
public enum DemucsModelContract {
    public static let sampleRate: Double = 44_100
    public static let mixInput = "mix"            // Float32 [1, 2, segment]
    public static let specInput = "spec"          // Float32 [1, 4, 2048, T]   (L.re, L.im, R.re, R.im)
    public static let specOutput = "spec_out"     // Float32 [1, S·4, 2048, T]
    public static let waveOutput = "wave_out"     // Float32 [1, S·2, segment]
    public static let defaultSegment = 343_980    // 7.8 s @ 44.1 kHz (htdemucs training segment)
    /// Source order of htdemucs_6s.
    public static let sources: [Stem] = [.drums, .bass, .other, .vocals, .guitar, .piano]
}

/// The network part of Demucs: one fixed-length segment in, per-source spectra + waveforms out.
/// Implemented with Core ML on macOS (`CoreMLDemucsCore`); tests use a fake.
public protocol DemucsCore {
    var segment: Int { get }
    var sourceCount: Int { get }
    /// `mix`: 2 × segment (channel-major). `spec`: 4 × 2048 × T. Returns
    /// spec: S·4 × 2048 × T and wave: S·2 × segment, both flat row-major.
    func run(mix: [Float], spec: [Float]) throws -> (spec: [Float], wave: [Float])
}

/// Demucs inference around a `DemucsCore`: whole-track normalisation, overlapping segments with
/// triangular cross-fades (as `demucs.apply.apply_model`, overlap 0.25), the spectral front end in
/// Swift, optional shift averaging (High quality), then drum-part splitting on the drum stem.
public struct NeuralStemSeparator: StemSeparator {
    public let name: String
    let core: DemucsCore
    public var overlap = 0.25

    public init(core: DemucsCore, name: String = "AI separation (Demucs v4, 6 stems)") {
        self.core = core; self.name = name
    }

    public func separate(_ audio: AudioData, options: SeparationOptions, progress: SeparationProgress,
                         isCancelled: () -> Bool) throws -> [Stem: AudioData] {
        let originalRate = audio.sampleRate
        var input = audio.stereo
        if abs(input.sampleRate - DemucsModelContract.sampleRate) > 0.5 {
            progress(0.01, "Resampling to 44.1 kHz")
            input = Resampler.resample(input, to: DemucsModelContract.sampleRate)
        }
        let n = input.frameCount
        guard n > 0 else { throw StudioForgeError.invalid("The audio is empty.") }
        // Sources to keep (drums are needed for drum parts).
        let order = DemucsModelContract.sources
        var wanted = Set(options.stems.filter { !$0.isDrumPart })
        if options.splitDrums { wanted.insert(.drums) }
        let keep = order.enumerated().filter { wanted.contains($0.element) }.map { $0.offset }
        guard !keep.isEmpty else { return [:] }

        // Whole-track normalisation (demucs.separate: (wav - mean) / std of the mono reference).
        let mono = input.mono
        let mean = mono.reduce(0, +) / Float(n)
        var varSum: Float = 0
        for v in mono { varSum += (v - mean) * (v - mean) }
        let std = max(1e-5, sqrtf(varSum / Float(max(1, n - 1))))
        let chans = input.channels.map { $0.map { ($0 - mean) / std } }

        let shifts = options.quality == .high ? [0, Int(0.25 * DemucsModelContract.sampleRate)] : [0]
        var acc = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: n), count: 2), count: keep.count)
        let seg = core.segment
        let stride = max(1, Int(Double(seg) * (1 - overlap)))
        let chunksPerPass = max(1, Int(ceil(Double(n) / Double(stride))))
        let total = chunksPerPass * shifts.count
        var done = 0
        for shift in shifts {
            // Shifted pass: the signal is delayed by `shift` samples and the result advanced back.
            let padded = shift == 0 ? chans : chans.map { [Float](repeating: 0, count: shift) + $0 }
            let out = try runPass(padded, length: n + shift, keep: keep, isCancelled: isCancelled) {
                done += 1
                progress(0.03 + 0.8 * Double(done) / Double(total), "Separating with AI (\(done)/\(total))")
            }
            for k in keep.indices { for c in 0..<2 { for i in 0..<n { acc[k][c][i] += out[k][c][i + shift] } } }
        }
        let g = std / Float(shifts.count)
        var result: [Stem: AudioData] = [:]
        for (k, s) in keep.enumerated() {
            var a = AudioData(channels: acc[k].map { $0.map { $0 * g + mean / Float(order.count) } },
                              sampleRate: DemucsModelContract.sampleRate)
            if abs(originalRate - a.sampleRate) > 0.5 { a = Resampler.resample(a, to: originalRate) }
            result[order[s]] = a
        }
        if options.splitDrums, let drums = result[.drums] {
            progress(0.88, "Splitting drum parts")
            for (k, v) in try DrumPartSplitter().split(drums, isCancelled: isCancelled) { result[k] = v }
        }
        result = result.filter { options.stems.contains($0.key) || ($0.key.isDrumPart && options.splitDrums) }
        progress(1, "Done")
        return result
    }

    /// One pass over the (normalised) signal. Returns [kept source][channel][sample].
    func runPass(_ x: [[Float]], length n: Int, keep: [Int], isCancelled: () -> Bool,
                 chunkDone: () -> Void) throws -> [[[Float]]] {
        let seg = core.segment
        let stride = max(1, Int(Double(seg) * (1 - overlap)))
        let spectral = DemucsSpectral()
        let t = spectral.frames(for: seg)
        let bins = spectral.bins
        // Triangular weight (apply_model, transition_power 1).
        var weight = [Float](repeating: 0, count: seg)
        let half = seg / 2
        for i in 0..<seg { weight[i] = Float(i < half ? i + 1 : seg - i) }
        let wMax = weight.max() ?? 1
        for i in 0..<seg { weight[i] /= wMax }
        var out = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: n), count: 2), count: keep.count)
        var wsum = [Float](repeating: 0, count: n)
        var offset = 0
        while offset < n {
            if isCancelled() { throw StudioForgeError.cancelled }
            let len = min(seg, n - offset)
            var mix = [Float](repeating: 0, count: 2 * seg)
            for c in 0..<2 { for i in 0..<len { mix[c * seg + i] = x[c][offset + i] } }
            var spec = [Float](repeating: 0, count: 4 * bins * t)
            for c in 0..<2 {
                let s = spectral.forward(Array(mix[(c * seg)..<((c + 1) * seg)]))
                spec.replaceSubrange((2 * c * bins * t)..<((2 * c + 1) * bins * t), with: s.re)
                spec.replaceSubrange(((2 * c + 1) * bins * t)..<((2 * c + 2) * bins * t), with: s.im)
            }
            let r = try core.run(mix: mix, spec: spec)
            let plane = bins * t
            for (k, s) in keep.enumerated() {
                for c in 0..<2 {
                    let reBase = (4 * s + 2 * c) * plane, imBase = reBase + plane
                    let y = r.spec.withUnsafeBufferPointer { p in
                        spectral.inverse(length: seg, frames: t, re: { p[reBase + $0 * t + $1] }, im: { p[imBase + $0 * t + $1] })
                    }
                    let waveBase = (2 * s + c) * seg
                    for i in 0..<len { out[k][c][offset + i] += (y[i] + r.wave[waveBase + i]) * weight[i] }
                }
            }
            for i in 0..<len { wsum[offset + i] += weight[i] }
            chunkDone()
            if offset + seg >= n { break }
            offset += stride
        }
        for k in out.indices { for c in 0..<2 { for i in 0..<n where wsum[i] > 0 { out[k][c][i] /= wsum[i] } } }
        return out
    }
}
