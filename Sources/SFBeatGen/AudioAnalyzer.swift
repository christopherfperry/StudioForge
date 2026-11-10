import Foundation
import SFCore

/// Result of analysing a recording for "match to recording" beat generation.
public struct AudioAnalysis: Codable, Hashable {
    public var bpm: Double
    /// 0...1, how clearly periodic the onset envelope is.
    public var tempoConfidence: Double
    /// Beat times in seconds.
    public var beats: [Double]
    /// Onset times in seconds.
    public var onsets: [Double]
    /// e.g. "A minor".
    public var key: String
    public var keyIsMinor: Bool
    public var keyRoot: Int  // 0 = C
    public var keyConfidence: Double
    /// 0...1 loudness-based energy.
    public var energy: Double
    /// Onsets per second.
    public var onsetDensity: Double
    /// 0...1 estimated swing of off-beat eighths.
    public var swing: Double
    public var duration: Double
}

/// Offline audio analysis: spectral-flux onset detection, autocorrelation tempo estimation,
/// dynamic-programming-free beat tracking (phase search + local snapping), chroma/Krumhansl key
/// detection and RMS energy. Uses the SFCore FFT (vDSP on Apple platforms).
public struct AudioAnalyzer {
    public var frameSize = 2048
    public var hop = 512
    public var minBPM = 60.0
    public var maxBPM = 200.0

    public init() {}

    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    // Krumhansl–Kessler key profiles.
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    public func analyze(_ audio: AudioData) -> AudioAnalysis { analyze(samples: audio.mono, sampleRate: audio.sampleRate) }

    public func analyze(samples: [Float], sampleRate: Double) -> AudioAnalysis {
        let duration = Double(samples.count) / sampleRate
        guard samples.count > frameSize * 2 else {
            return AudioAnalysis(bpm: 120, tempoConfidence: 0, beats: [], onsets: [], key: "C major", keyIsMinor: false,
                                 keyRoot: 0, keyConfidence: 0, energy: 0, onsetDensity: 0, swing: 0, duration: duration)
        }
        let stft = STFT(frameSize: frameSize, hop: hop)
        let (re, im, frames) = stft.analyze(samples)
        let bins = stft.bins
        let frameRate = sampleRate / Double(hop)

        // --- Magnitudes, onset envelope (log spectral flux) and chroma in one pass.
        var flux = [Double](repeating: 0, count: frames)
        var prev = [Float](repeating: 0, count: bins)
        var cur = [Float](repeating: 0, count: bins)
        var chroma = [Double](repeating: 0, count: 12)
        let binHz = sampleRate / Double(frameSize)
        // Pitch class per bin (only 55 Hz – 4 kHz contribute to chroma).
        let pitchClass: [Int] = (0..<bins).map { b in
            let f = Double(b) * binHz
            guard f >= 55, f <= 4000 else { return -1 }
            let midi = 69 + 12 * log2(f / 440)
            return ((Int(midi.rounded()) % 12) + 12) % 12
        }
        for f in 0..<frames {
            let base = f * bins
            var sum: Double = 0
            for b in 0..<bins {
                let m = sqrtf(re[base + b] * re[base + b] + im[base + b] * im[base + b])
                let lm = logf(1 + 100 * m)
                cur[b] = lm
                let d = lm - prev[b]
                if d > 0 { sum += Double(d) }
                let pc = pitchClass[b]
                if pc >= 0 { chroma[pc] += Double(m) }
            }
            flux[f] = f == 0 ? 0 : sum
            swap(&prev, &cur)
        }
        // Normalise and remove local mean (adaptive threshold).
        let onsetEnv = Self.normalise(Self.subtractLocalMean(flux, radius: 8))

        // --- Onsets: peak picking.
        var onsets: [Double] = []
        let minGap = Int(0.05 * frameRate)
        var lastPeak = -minGap
        for i in 1..<(frames - 1) where onsetEnv[i] > 0.12 && onsetEnv[i] >= onsetEnv[i - 1] && onsetEnv[i] > onsetEnv[i + 1] {
            if i - lastPeak >= minGap {
                onsets.append(Double(i) / frameRate)
                lastPeak = i
            }
        }

        // --- Tempo: autocorrelation of the onset envelope with a log-Gaussian prior around 120 BPM.
        let (bpm, confidence, periodFrames) = estimateTempo(onsetEnv, frameRate: frameRate)

        // --- Beat tracking: choose the phase maximising onset energy on the beat grid, then snap
        // every predicted beat to the strongest nearby onset (±15% of a period).
        var beats: [Double] = []
        if periodFrames > 1 {
            let p = periodFrames
            var bestPhase = 0.0, bestScore = -1.0
            let steps = max(1, Int(p.rounded()))
            for ph in 0..<steps {
                var s = 0.0
                var t = Double(ph)
                while Int(t) < frames { s += onsetEnv[Int(t)]; t += p }
                if s > bestScore { bestScore = s; bestPhase = Double(ph) }
            }
            var t = bestPhase
            let win = max(1, Int(p * 0.15))
            while Int(t) < frames {
                let c = Int(t.rounded())
                var best = c, bv = -1.0
                for j in max(0, c - win)...min(frames - 1, c + win) where onsetEnv[j] > bv { bv = onsetEnv[j]; best = j }
                // Only snap if there is a real onset; otherwise keep the grid.
                let snapped = bv > 0.2 ? Double(best) : t
                beats.append(snapped / frameRate)
                t = snapped + p
            }
        }

        // --- Swing: where does the strongest onset between two beats fall? 0.5 = straight, 0.667 = triplet.
        var swingAcc = 0.0, swingN = 0.0
        if beats.count > 2 {
            for i in 0..<(beats.count - 1) {
                let a = beats[i] * frameRate, b = beats[i + 1] * frameRate
                let lo = Int(a + (b - a) * 0.4), hi = Int(a + (b - a) * 0.75)
                guard hi > lo, hi < frames else { continue }
                var best = lo, bv = 0.0
                for j in lo...hi where onsetEnv[j] > bv { bv = onsetEnv[j]; best = j }
                if bv > 0.25 {
                    let frac = (Double(best) - a) / (b - a)
                    swingAcc += min(1, max(0, (frac - 0.5) / (2.0 / 3.0 - 0.5))) * bv
                    swingN += bv
                }
            }
        }
        let swing = swingN > 0 ? min(1, swingAcc / swingN) : 0

        // --- Key from chroma correlation with rotated profiles.
        let (root, minor, keyConf) = Self.detectKey(chroma)

        // --- Energy: RMS mapped from dBFS (-40 dB -> 0, -6 dB -> 1).
        var sq: Double = 0
        for s in samples { sq += Double(s) * Double(s) }
        let rms = sqrt(sq / Double(samples.count))
        let db = 20 * log10(max(rms, 1e-9))
        let energy = min(1, max(0, (db + 40) / 34))

        return AudioAnalysis(bpm: bpm, tempoConfidence: confidence, beats: beats, onsets: onsets,
                             key: "\(Self.noteNames[root]) \(minor ? "minor" : "major")", keyIsMinor: minor, keyRoot: root,
                             keyConfidence: keyConf, energy: energy, onsetDensity: Double(onsets.count) / max(duration, 0.001),
                             swing: swing, duration: duration)
    }

    /// Returns (bpm, confidence 0...1, period in frames).
    func estimateTempo(_ env: [Double], frameRate: Double) -> (Double, Double, Double) {
        let n = env.count
        let minLag = max(1, Int(frameRate * 60 / maxBPM))
        let maxLag = min(n - 1, Int(frameRate * 60 / minBPM))
        guard maxLag > minLag + 1 else { return (120, 0, frameRate * 0.5) }
        var ac = [Double](repeating: 0, count: maxLag + 2)
        var zero = 0.0
        for i in 0..<n { zero += env[i] * env[i] }
        for lag in minLag...(maxLag + 1) where lag < n {
            var s = 0.0
            for i in 0..<(n - lag) { s += env[i] * env[i + lag] }
            ac[lag] = s / Double(n - lag)
        }
        // Weight each lag by a log-Gaussian tempo prior centred at 120 BPM and add energy from the
        // double-period (helps choose the beat rather than the half-beat).
        var bestLag = minLag, bestScore = -Double.infinity
        for lag in minLag...maxLag {
            let bpm = 60 * frameRate / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 1.0, 2))
            let harmonic = 2 * lag <= maxLag + 1 ? 0.5 * ac[2 * lag] : 0
            let score = (ac[lag] + harmonic) * prior
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        // Parabolic interpolation for sub-frame precision.
        var lagF = Double(bestLag)
        if bestLag > minLag && bestLag < maxLag {
            let a = ac[bestLag - 1], b = ac[bestLag], c = ac[bestLag + 1]
            let denom = a - 2 * b + c
            if abs(denom) > 1e-12 { lagF += 0.5 * (a - c) / denom }
        }
        let bpm = 60 * frameRate / lagF
        let meanAC = ac[minLag...maxLag].reduce(0, +) / Double(maxLag - minLag + 1)
        let conf = zero > 0 ? min(1, max(0, (ac[bestLag] - meanAC) / (zero / Double(n) - meanAC + 1e-9))) : 0
        return (bpm, conf, lagF)
    }

    static func detectKey(_ chroma: [Double]) -> (Int, Bool, Double) {
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            return da > 0 && db > 0 ? num / sqrt(da * db) : 0
        }
        var best = (0, false, -2.0)
        for root in 0..<12 {
            let rotated = (0..<12).map { chroma[($0 + root) % 12] }
            let cMaj = corr(rotated, majorProfile), cMin = corr(rotated, minorProfile)
            if cMaj > best.2 { best = (root, false, cMaj) }
            if cMin > best.2 { best = (root, true, cMin) }
        }
        return (best.0, best.1, max(0, best.2))
    }

    static func subtractLocalMean(_ x: [Double], radius: Int) -> [Double] {
        guard !x.isEmpty else { return x }
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + x[i] }
        return (0..<x.count).map { i in
            let lo = max(0, i - radius), hi = min(x.count, i + radius + 1)
            let mean = (prefix[hi] - prefix[lo]) / Double(hi - lo)
            return max(0, x[i] - mean)
        }
    }

    static func normalise(_ x: [Double]) -> [Double] {
        let m = x.max() ?? 0
        return m > 0 ? x.map { $0 / m } : x
    }
}
