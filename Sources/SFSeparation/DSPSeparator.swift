import Foundation
import SFCore

/// Complex spectrogram of one channel (frames × bins, row-major by frame).
public struct Spectrogram {
    public var re: [Float]
    public var im: [Float]
    public var frames: Int
    public var bins: Int
    public var length: Int

    public func magnitude() -> [Float] {
        var m = [Float](repeating: 0, count: re.count)
        for i in 0..<re.count { m[i] = sqrtf(re[i] * re[i] + im[i] * im[i]) }
        return m
    }
    /// Applies a real mask (same layout) and returns a new spectrogram.
    public func masked(_ mask: [Float]) -> Spectrogram {
        var r = re, i = im
        for k in 0..<mask.count { r[k] *= mask[k]; i[k] *= mask[k] }
        return Spectrogram(re: r, im: i, frames: frames, bins: bins, length: length)
    }
}

/// Harmonic/percussive source separation by median filtering (Fitzgerald 2010) with soft
/// Wiener-style masks. Harmonic = median across time, percussive = median across frequency.
public struct HPSS {
    public var harmonicKernel = 17
    public var percussiveKernel = 17
    public var power: Float = 2

    public init(harmonicKernel: Int = 17, percussiveKernel: Int = 17) {
        self.harmonicKernel = harmonicKernel; self.percussiveKernel = percussiveKernel
    }

    /// Returns (harmonicMask, percussiveMask) for a magnitude spectrogram; masks sum to 1.
    public func masks(magnitude m: [Float], frames: Int, bins: Int) -> (harmonic: [Float], percussive: [Float]) {
        var h = [Float](repeating: 0, count: m.count)
        var p = [Float](repeating: 0, count: m.count)
        let hk = harmonicKernel / 2, pk = percussiveKernel / 2
        var window = [Float](repeating: 0, count: max(harmonicKernel, percussiveKernel) + 1)
        // Harmonic: median over time for each bin.
        for b in 0..<bins {
            for f in 0..<frames {
                var n = 0
                for t in max(0, f - hk)...min(frames - 1, f + hk) { window[n] = m[t * bins + b]; n += 1 }
                h[f * bins + b] = Self.median(&window, n)
            }
        }
        // Percussive: median over frequency for each frame.
        for f in 0..<frames {
            let base = f * bins
            for b in 0..<bins {
                var n = 0
                for k in max(0, b - pk)...min(bins - 1, b + pk) { window[n] = m[base + k]; n += 1 }
                p[base + b] = Self.median(&window, n)
            }
        }
        var hm = [Float](repeating: 0, count: m.count), pm = hm
        for i in 0..<m.count {
            let hp = powf(h[i], power), pp = powf(p[i], power)
            let s = hp + pp
            if s > 1e-20 { hm[i] = hp / s; pm[i] = pp / s } else { hm[i] = 0.5; pm[i] = 0.5 }
        }
        return (hm, pm)
    }

    /// Median of the first `n` values (insertion sort; n is small).
    @inline(__always) static func median(_ a: inout [Float], _ n: Int) -> Float {
        if n <= 0 { return 0 }
        for i in 1..<max(1, n) {
            let v = a[i]; var j = i - 1
            while j >= 0 && a[j] > v { a[j + 1] = a[j]; j -= 1 }
            a[j + 1] = v
        }
        return n % 2 == 1 ? a[n / 2] : 0.5 * (a[n / 2 - 1] + a[n / 2])
    }

    /// Convenience: split a mono signal into harmonic and percussive parts.
    public func separate(_ x: [Float], frameSize: Int = 2048, hop: Int = 512) -> (harmonic: [Float], percussive: [Float]) {
        let stft = STFT(frameSize: frameSize, hop: hop)
        let a = stft.analyze(x)
        let spec = Spectrogram(re: a.re, im: a.im, frames: a.frames, bins: stft.bins, length: x.count)
        let (hm, pm) = masks(magnitude: spec.magnitude(), frames: spec.frames, bins: spec.bins)
        let hs = spec.masked(hm), ps = spec.masked(pm)
        return (stft.synthesize(re: hs.re, im: hs.im, frames: hs.frames, length: x.count),
                stft.synthesize(re: ps.re, im: ps.im, frames: ps.frames, length: x.count))
    }
}

/// Band/feature-based drum-part splitter. Works on a (percussive or full-drum) stem and assigns
/// each time–frequency bin to kick / snare / toms / hi-hat / cymbals using soft masks built from
/// frequency bands weighted by per-frame features (low-band onset strength, mid-band noisiness,
/// high-band sustain). A baseline approach — documented in docs/ARCHITECTURE.md.
public struct DrumPartSplitter {
    public init() {}

    /// Soft band-pass weight: 0 below a, ramps to 1 at b, flat to c, ramps to 0 at d.
    @inline(__always) static func band(_ f: Float, _ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
        if f <= a || f >= d { return 0 }
        if f < b { return (f - a) / (b - a) }
        if f <= c { return 1 }
        return (d - f) / (d - c)
    }

    /// Returns masks keyed by drum part, each frames × bins, summing to ≤ 1 per bin.
    public func masks(magnitude m: [Float], frames: Int, bins: Int, sampleRate: Double, frameSize: Int, hop: Int) -> [Stem: [Float]] {
        let binHz = Float(sampleRate / Double(frameSize))
        func bandEnergy(_ f: Int, _ lo: Float, _ hi: Float) -> Float {
            let b0 = max(0, Int(lo / binHz)), b1 = min(bins - 1, Int(hi / binHz))
            guard b1 >= b0 else { return 0 }
            var s: Float = 0
            for b in b0...b1 { let v = m[f * bins + b]; s += v * v }
            return s
        }
        var low = [Float](repeating: 0, count: frames), lowMid = low, mid = low, high = low
        for f in 0..<frames {
            low[f] = bandEnergy(f, 30, 140); lowMid[f] = bandEnergy(f, 140, 500)
            mid[f] = bandEnergy(f, 500, 4000); high[f] = bandEnergy(f, 6000, 16000)
        }
        // Sustain of the high band = smoothed energy / recent peak. A short hi-hat burst leaves the
        // ~0.3 s average far below its peak (low sustain); a ringing cymbal keeps them close.
        // (Previously the ratio was current/peak, which is 1 at every fresh hit, so hats were
        // classified as cymbals.)
        let frameRate = Float(sampleRate) / Float(hop)
        let avgCoef = expf(-1 / (0.3 * frameRate)), peakCoef = expf(-1 / (0.6 * frameRate))
        var avg: Float = 0, peak: Float = 0
        var sustain = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            let x = high[f]
            avg = avgCoef * avg + (1 - avgCoef) * x
            peak = max(x, peak * peakCoef)
            sustain[f] = peak > 1e-12 ? min(1, 3 * avg / peak) : 0
        }
        // Onset strength per band (half-wave rectified difference) to emphasise transients.
        func onset(_ e: [Float]) -> [Float] {
            var o = [Float](repeating: 0, count: e.count)
            for i in 1..<max(1, e.count) { o[i] = max(0, sqrtf(e[i]) - sqrtf(e[i - 1])) }
            let mx = o.max() ?? 0
            return mx > 0 ? o.map { $0 / mx } : o
        }
        let lowOn = onset(low), lowMidOn = onset(lowMid), midOn = onset(mid)
        // Smooth onsets with a short decay so the body of each hit follows its classification.
        func hold(_ o: [Float], seconds: Float) -> [Float] {
            let c = expf(-1 / (seconds * frameRate)); var v: Float = 0
            return o.map { x in v = max(x, v * c); return v }
        }
        let kickF = hold(lowOn, seconds: 0.25)
        // Toms: low-mid onsets that are neither a kick (low band) nor a snare (broadband mid).
        var tomOn = [Float](repeating: 0, count: frames)
        for f in 0..<frames { tomOn[f] = max(0, lowMidOn[f] - 0.5 * midOn[f] - 0.8 * lowOn[f]) }
        let tomF = hold(tomOn, seconds: 0.35)
        let snareF = hold(midOn, seconds: 0.18)

        var out: [Stem: [Float]] = [:]
        for s in Stem.drumParts { out[s] = [Float](repeating: 0, count: m.count) }
        var kM = out[.kick]!, sM = out[.snare]!, tM = out[.toms]!, hM = out[.hihat]!, cM = out[.cymbals]!
        for f in 0..<frames {
            let base = f * bins
            for b in 0..<bins {
                let hz = Float(b) * binHz
                let wk = Self.band(hz, 20, 40, 110, 180) * (0.15 + kickF[f])
                let wt = Self.band(hz, 60, 90, 350, 700) * (0.02 + tomF[f]) * (1 - 0.8 * kickF[f])
                let ws = Self.band(hz, 150, 220, 3500, 8000) * (0.1 + snareF[f])
                let wh = Self.band(hz, 4000, 7000, 20000, 24000) * (1.05 - sustain[f])
                let wc = Self.band(hz, 2500, 5000, 20000, 24000) * (0.05 + sustain[f])
                let sum = wk + wt + ws + wh + wc
                guard sum > 1e-9 else { continue }
                kM[base + b] = wk / sum; tM[base + b] = wt / sum; sM[base + b] = ws / sum
                hM[base + b] = wh / sum; cM[base + b] = wc / sum
            }
        }
        out[.kick] = kM; out[.snare] = sM; out[.toms] = tM; out[.hihat] = hM; out[.cymbals] = cM
        return out
    }

    /// Splits a drum stem into parts.
    public func split(_ drums: AudioData, frameSize: Int = 2048, hop: Int = 512, isCancelled: () -> Bool = { false }) throws -> [Stem: AudioData] {
        let stft = STFT(frameSize: frameSize, hop: hop)
        var result: [Stem: [[Float]]] = [:]
        for ch in drums.channels {
            if isCancelled() { throw StudioForgeError.cancelled }
            let a = stft.analyze(ch)
            let spec = Spectrogram(re: a.re, im: a.im, frames: a.frames, bins: stft.bins, length: ch.count)
            let ms = masks(magnitude: spec.magnitude(), frames: spec.frames, bins: spec.bins,
                           sampleRate: drums.sampleRate, frameSize: frameSize, hop: hop)
            for (stem, mask) in ms {
                let s = spec.masked(mask)
                result[stem, default: []].append(stft.synthesize(re: s.re, im: s.im, frames: s.frames, length: ch.count))
            }
        }
        return result.mapValues { AudioData(channels: $0, sampleRate: drums.sampleRate) }
    }
}

/// Model-free stem separator:
///  1. HPSS on each channel → harmonic + percussive.
///  2. Drums = percussive (optionally split into parts).
///  3. Bass = harmonic below ~200 Hz (soft crossover).
///  4. Vocals = harmonic, centre-panned (inter-channel similarity), 180 Hz – 8 kHz.
///  5. Guitar/other = remaining harmonic content.
/// Quality is far below the ML model but needs no download and is fast.
public struct DSPStemSeparator: StemSeparator {
    public let name = "DSP (HPSS + band masks)"
    public var frameSize = 4096
    public var hop = 1024

    public init() {}

    public func separate(_ audio: AudioData, options: SeparationOptions, progress: SeparationProgress,
                         isCancelled: () -> Bool) throws -> [Stem: AudioData] {
        let input = audio.stereo
        let sr = input.sampleRate
        let stft = STFT(frameSize: frameSize, hop: hop)
        let bins = stft.bins
        let n = input.frameCount
        progress(0.02, "Analysing spectrum")
        let specs: [Spectrogram] = input.channels.map { ch in
            let a = stft.analyze(ch)
            return Spectrogram(re: a.re, im: a.im, frames: a.frames, bins: bins, length: n)
        }
        if isCancelled() { throw StudioForgeError.cancelled }
        let mags = specs.map { $0.magnitude() }
        let frames = specs[0].frames
        // HPSS on the mid magnitude so both channels share one mask (keeps the stereo image).
        var midMag = [Float](repeating: 0, count: mags[0].count)
        for i in 0..<midMag.count { midMag[i] = 0.5 * (mags[0][i] + mags[1][i]) }
        progress(0.15, "Harmonic / percussive separation")
        let (hMask, pMask) = HPSS(harmonicKernel: 17, percussiveKernel: 17).masks(magnitude: midMag, frames: frames, bins: bins)
        if isCancelled() { throw StudioForgeError.cancelled }
        progress(0.5, "Building stem masks")

        let binHz = Float(sr / Double(frameSize))
        let wantGuitar = options.stems.contains(.guitar)
        let wantPiano = options.stems.contains(.piano)
        let wantOther = options.stems.contains(.other)
        var bassMask = [Float](repeating: 0, count: midMag.count)
        var vocalMask = bassMask, guitarMask = bassMask, pianoMask = bassMask, otherMask = bassMask
        for f in 0..<frames {
            let base = f * bins
            for b in 0..<bins {
                let i = base + b
                let hz = Float(b) * binHz
                let h = hMask[i]
                // Bass crossover: 1 below 120 Hz, 0 above 250 Hz.
                let bassW: Float = hz <= 120 ? 1 : (hz >= 250 ? 0 : (250 - hz) / 130)
                // Centre-ness: 2|L||R|cosΔφ / (|L|²+|R|²) ≈ 1 for centre-panned, in-phase sources.
                let lr = specs[0].re[i] * specs[1].re[i] + specs[0].im[i] * specs[1].im[i]
                let pw = mags[0][i] * mags[0][i] + mags[1][i] * mags[1][i]
                let centre: Float = pw > 1e-12 ? min(1, max(0, 2 * lr / pw)) : 0
                let vocalBand = DrumPartSplitter.band(hz, 150, 250, 6000, 9000)
                let vW = powf(centre, 6) * vocalBand * (1 - bassW)
                bassMask[i] = h * bassW
                vocalMask[i] = h * vW
                let residual = max(0, h - bassMask[i] - vocalMask[i])
                // Residual harmonic content is shared between guitar / piano-keys / other with soft
                // band + stereo-width weights (guitars tend to sit wide in the mids, keys span the
                // low-mids and are more centred, pads/strings/synth air sit higher). Heuristic only.
                let side = 1 - centre
                let gW = wantGuitar ? DrumPartSplitter.band(hz, 80, 200, 2500, 5000) * (0.35 + side) : 0
                let pW = wantPiano ? DrumPartSplitter.band(hz, 27, 60, 1500, 4500) * (0.35 + centre) : 0
                let oW: Float = DrumPartSplitter.band(hz, 2000, 5000, 20000, 24000) + 0.25
                let sum = gW + pW + oW
                if wantOther {
                    // "Other" absorbs everything that isn't assigned to a requested stem.
                    guitarMask[i] = residual * gW / sum
                    pianoMask[i] = residual * pW / sum
                    otherMask[i] = max(0, residual - guitarMask[i] - pianoMask[i])
                } else if gW + pW > 1e-9 {
                    guitarMask[i] = residual * gW / (gW + pW)
                    pianoMask[i] = residual * pW / (gW + pW)
                }
            }
        }
        var masks: [Stem: [Float]] = [:]
        let wantDrums = options.stems.contains(.drums) || options.splitDrums
        if options.stems.contains(.bass) { masks[.bass] = bassMask }
        if options.stems.contains(.vocals) { masks[.vocals] = vocalMask }
        if wantGuitar { masks[.guitar] = guitarMask }
        if wantPiano { masks[.piano] = pianoMask }
        if wantOther { masks[.other] = otherMask }
        if wantDrums { masks[.drums] = pMask }

        var result: [Stem: AudioData] = [:]
        var done = 0
        for (stem, mask) in masks {
            if isCancelled() { throw StudioForgeError.cancelled }
            let chans = specs.map { s -> [Float] in
                let m = s.masked(mask)
                return stft.synthesize(re: m.re, im: m.im, frames: m.frames, length: n)
            }
            result[stem] = AudioData(channels: chans, sampleRate: sr)
            done += 1
            progress(0.5 + 0.3 * Double(done) / Double(max(1, masks.count)), "Rendering \(stem.displayName)")
        }
        if options.splitDrums, let drums = result[.drums] {
            progress(0.82, "Splitting drum parts")
            let parts = try DrumPartSplitter().split(drums, isCancelled: isCancelled)
            for (k, v) in parts { result[k] = v }
            if !options.stems.contains(.drums) { result[.drums] = nil }
        }
        progress(1, "Done")
        return result
    }
}
