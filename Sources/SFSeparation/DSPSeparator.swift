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


/// Model-free stem separator.
///
/// Standard quality:
///  1. HPSS on the mid magnitude → harmonic + percussive masks (shared by both channels).
///  2. Drums = percussive (optionally split into parts).
///  3. Bass = harmonic below ~200 Hz (soft crossover).
///  4. Vocals = harmonic, centre-panned (inter-channel similarity), 150 Hz – 9 kHz.
///  5. Guitar / keys / other = remaining harmonic content (band + stereo-width weights).
///
/// High quality adds:
///  - a second HPSS pass on the harmonic part (longer time kernel) to strip residual transients;
///  - centre detection from time–frequency-smoothed inter-channel coherence (less flicker);
///  - pitch-aware bass: per-frame bass f0 (35–300 Hz) and its harmonics go to the bass stem;
///  - Wiener-style refinement: masks re-estimated from smoothed stem power ratios;
///  - multi-resolution drums: a short-window (1024) HPSS on the drum stem moves tonal bleed
///    above ~300 Hz out of the drums and sharpens attacks.
///
/// Optional artefact reduction (`SeparationOptions.artefactReduction`) runs `ArtefactReducer`
/// on the masks before resynthesis. Quality remains well below neural separators (e.g. Demucs).
public struct DSPStemSeparator: StemSeparator {
    public let name = "DSP (HPSS + band masks)"
    public var frameSize = 4096
    public var hop = 1024

    public init() {}

    /// Mask classes that always partition the mix (requested stems are picked from these).
    enum Part: Int, CaseIterable { case drums, bass, vocals, guitar, piano, other, rest }

    public func separate(_ audio: AudioData, options: SeparationOptions, progress: SeparationProgress,
                         isCancelled: () -> Bool) throws -> [Stem: AudioData] {
        let input = audio.stereo
        let sr = input.sampleRate
        let stft = STFT(frameSize: frameSize, hop: hop)
        let bins = stft.bins
        let n = input.frameCount
        let high = options.quality == .high
        progress(0.02, "Analysing spectrum")
        let specs: [Spectrogram] = input.channels.map { ch in
            let a = stft.analyze(ch)
            return Spectrogram(re: a.re, im: a.im, frames: a.frames, bins: bins, length: n)
        }
        if isCancelled() { throw StudioForgeError.cancelled }
        let mags = specs.map { $0.magnitude() }
        let frames = specs[0].frames
        let count = mags[0].count
        // HPSS on the mid magnitude so both channels share one mask (keeps the stereo image).
        var midMag = [Float](repeating: 0, count: count)
        for i in 0..<count { midMag[i] = 0.5 * (mags[0][i] + mags[1][i]) }
        progress(0.1, "Harmonic / percussive separation")
        var (hMask, pMask) = HPSS(harmonicKernel: 17, percussiveKernel: 17).masks(magnitude: midMag, frames: frames, bins: bins)
        if isCancelled() { throw StudioForgeError.cancelled }
        if high {
            progress(0.25, "Second harmonic pass")
            var hMag = [Float](repeating: 0, count: count)
            for i in 0..<count { hMag[i] = midMag[i] * hMask[i] }
            let (h2, _) = HPSS(harmonicKernel: 31, percussiveKernel: 9).masks(magnitude: hMag, frames: frames, bins: bins)
            for i in 0..<count { hMask[i] *= h2[i]; pMask[i] = 1 - hMask[i] }
            if isCancelled() { throw StudioForgeError.cancelled }
        }
        progress(0.4, "Building stem masks")

        let binHz = Float(sr / Double(frameSize))
        let centre = Self.centreness(specs, mags, frames: frames, bins: bins, smooth: high)
        let bassF0 = high ? Self.bassF0(midMag, hMask, frames: frames, bins: bins, binHz: binHz) : []
        let wantGuitar = options.stems.contains(.guitar)
        let wantPiano = options.stems.contains(.piano)
        let wantOther = options.stems.contains(.other)
        var parts = [[Float]](repeating: [Float](repeating: 0, count: count), count: Part.allCases.count)
        parts[Part.drums.rawValue] = pMask
        for f in 0..<frames {
            let base = f * bins
            let f0 = high ? bassF0[f] : 0
            for b in 0..<bins {
                let i = base + b
                let hz = Float(b) * binHz
                let h = hMask[i]
                var bassW: Float
                if high {
                    bassW = hz <= 100 ? 1 : (hz >= 200 ? 0 : (200 - hz) / 100)
                    if f0 > 0 { bassW = max(bassW, Self.combWeight(hz, f0: f0, binHz: binHz)) }
                } else {
                    // Bass crossover: 1 below 120 Hz, 0 above 250 Hz.
                    bassW = hz <= 120 ? 1 : (hz >= 250 ? 0 : (250 - hz) / 130)
                }
                let c = centre[i]
                let vocalBand = DrumPartSplitter.band(hz, 150, 250, 6000, 9000)
                let vW = powf(c, high ? 4 : 6) * vocalBand * (1 - bassW)
                let bass = h * bassW
                let vocal = h * vW
                parts[Part.bass.rawValue][i] = bass
                parts[Part.vocals.rawValue][i] = vocal
                let residual = max(0, h - bass - vocal)
                // Residual harmonic content is shared between guitar / piano-keys / other with soft
                // band + stereo-width weights (guitars tend to sit wide in the mids, keys span the
                // low-mids and are more centred, pads/strings/synth air sit higher). Heuristic only.
                let side = 1 - c
                let gW = wantGuitar ? DrumPartSplitter.band(hz, 80, 200, 2500, 5000) * (0.35 + side) : 0
                let pW = wantPiano ? DrumPartSplitter.band(hz, 27, 60, 1500, 4500) * (0.35 + c) : 0
                let oW: Float = DrumPartSplitter.band(hz, 2000, 5000, 20000, 24000) + 0.25
                var g: Float = 0, p: Float = 0
                if wantOther {
                    let sum = gW + pW + oW
                    g = residual * gW / sum; p = residual * pW / sum
                    parts[Part.other.rawValue][i] = max(0, residual - g - p)
                } else if gW + pW > 1e-9 {
                    g = residual * gW / (gW + pW); p = residual * pW / (gW + pW)
                } else {
                    parts[Part.rest.rawValue][i] = residual
                }
                parts[Part.guitar.rawValue][i] = g
                parts[Part.piano.rawValue][i] = p
            }
        }
        if isCancelled() { throw StudioForgeError.cancelled }
        if high {
            progress(0.55, "Wiener refinement")
            parts = Self.wienerRefine(parts, midMag: midMag, frames: frames, bins: bins)
        }
        if options.artefactReduction > 0 {
            progress(0.62, "Reducing artefacts")
            parts = ArtefactReducer(strength: options.artefactReduction)
                .refine(parts, mixMagnitude: midMag, frames: frames, bins: bins, binHz: binHz)
        }
        if isCancelled() { throw StudioForgeError.cancelled }

        var masks: [Stem: [Float]] = [:]
        let wantDrums = options.stems.contains(.drums) || options.splitDrums
        if options.stems.contains(.bass) { masks[.bass] = parts[Part.bass.rawValue] }
        if options.stems.contains(.vocals) { masks[.vocals] = parts[Part.vocals.rawValue] }
        if wantGuitar { masks[.guitar] = parts[Part.guitar.rawValue] }
        if wantPiano { masks[.piano] = parts[Part.piano.rawValue] }
        if wantOther { masks[.other] = parts[Part.other.rawValue] }
        if wantDrums { masks[.drums] = parts[Part.drums.rawValue] }

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
            progress(0.65 + 0.15 * Double(done) / Double(max(1, masks.count)), "Rendering \(stem.displayName)")
        }
        if high, let drums = result[.drums] {
            progress(0.8, "Refining drums")
            let (clean, tonal) = Self.refineDrums(drums)
            result[.drums] = clean
            // Tonal bleed goes where it belongs best: "Other", else guitar, else it is dropped.
            if let target: Stem = wantOther ? .other : (wantGuitar ? .guitar : nil), let t = result[target] {
                result[target] = Self.add(t, tonal)
            }
        }
        if options.splitDrums, let drums = result[.drums] {
            progress(0.85, "Splitting drum parts")
            let parts = try DrumPartSplitter().split(drums, isCancelled: isCancelled)
            for (k, v) in parts { result[k] = v }
            if !options.stems.contains(.drums) { result[.drums] = nil }
        }
        progress(1, "Done")
        return result
    }

    // MARK: - Helpers

    /// Centre-ness per bin: 2·Re(L·R*) / (|L|²+|R|²) ≈ 1 for centre-panned, in-phase sources.
    /// With `smooth`, numerator and denominator are averaged over 3×3 time–frequency cells
    /// (a coherence estimate), which is far more stable than the single-bin value.
    static func centreness(_ specs: [Spectrogram], _ mags: [[Float]], frames: Int, bins: Int, smooth: Bool) -> [Float] {
        let count = mags[0].count
        var cross = [Float](repeating: 0, count: count), power = cross
        for i in 0..<count {
            cross[i] = specs[0].re[i] * specs[1].re[i] + specs[0].im[i] * specs[1].im[i]
            power[i] = mags[0][i] * mags[0][i] + mags[1][i] * mags[1][i]
        }
        if smooth {
            cross = MaskOps.boxBlur(cross, frames: frames, bins: bins, rt: 1, rf: 1)
            power = MaskOps.boxBlur(power, frames: frames, bins: bins, rt: 1, rf: 1)
        }
        var c = [Float](repeating: 0, count: count)
        for i in 0..<count where power[i] > 1e-12 { c[i] = min(1, max(0, 2 * cross[i] / power[i])) }
        return c
    }

    /// Per-frame bass fundamental (Hz, 0 = none): the lowest strong harmonic peak in 35–300 Hz.
    static func bassF0(_ mag: [Float], _ hMask: [Float], frames: Int, bins: Int, binHz: Float) -> [Float] {
        let lo = max(1, Int(35 / binHz)), hi = min(bins - 2, Int(300 / binHz))
        var out = [Float](repeating: 0, count: frames)
        guard hi > lo else { return out }
        for f in 0..<frames {
            let base = f * bins
            var bandMax: Float = 0, frameMax: Float = 0
            for b in 0..<bins {
                let v = mag[base + b] * hMask[base + b]
                frameMax = max(frameMax, v)
                if b >= lo && b <= hi { bandMax = max(bandMax, v) }
            }
            guard bandMax > 1e-6, bandMax > 0.1 * frameMax else { continue }
            for b in lo...hi {
                let v = mag[base + b] * hMask[base + b]
                let l = mag[base + b - 1] * hMask[base + b - 1], r = mag[base + b + 1] * hMask[base + b + 1]
                if v >= 0.5 * bandMax && v >= l && v >= r {
                    // Parabolic interpolation of the peak position.
                    let d = l - 2 * v + r
                    let off = abs(d) > 1e-12 ? 0.5 * (l - r) / d : 0
                    out[f] = (Float(b) + max(-0.5, min(0.5, off))) * binHz
                    break
                }
            }
        }
        return out
    }

    /// Weight of a bin at `hz` belonging to the harmonic series of `f0` (up to 1.5 kHz).
    @inline(__always) static func combWeight(_ hz: Float, f0: Float, binHz: Float) -> Float {
        guard hz > 0.5 * f0, hz < 1500 else { return 0 }
        let k = max(1, (hz / f0).rounded())
        guard k <= 10 else { return 0 }
        let sigma = max(1.2 * binHz, 0.015 * k * f0)
        let d = (hz - k * f0) / sigma
        return expf(-0.5 * d * d) * (k <= 1 ? 1 : 0.85 / (1 + 0.2 * (k - 2)))
    }

    /// One Wiener iteration: mask_j = P_j / Σ P_k with P_j the smoothed power of stem j's estimate.
    static func wienerRefine(_ parts: [[Float]], midMag: [Float], frames: Int, bins: Int) -> [[Float]] {
        let count = midMag.count
        var powers: [[Float]] = parts.map { m in
            var p = [Float](repeating: 0, count: count)
            for i in 0..<count { let s = m[i] * midMag[i]; p[i] = s * s }
            return MaskOps.boxBlur(p, frames: frames, bins: bins, rt: 1, rf: 1)
        }
        for i in 0..<count {
            var sum: Float = 0
            for k in powers.indices { powers[k][i] = max(0, powers[k][i]); sum += powers[k][i] }
            if sum > 1e-20 && sum.isFinite {
                for k in powers.indices { powers[k][i] /= sum }
            } else {
                for k in powers.indices { powers[k][i] = parts[k][i] }
            }
        }
        return powers
    }

    /// Short-window HPSS on the drum stem: returns (drums, tonal bleed above ~300 Hz).
    static func refineDrums(_ drums: AudioData) -> (AudioData, AudioData) {
        let size = 1024, hop = 256
        let stft = STFT(frameSize: size, hop: hop)
        let binHz = Float(drums.sampleRate / Double(size))
        var clean: [[Float]] = [], tonal: [[Float]] = []
        for ch in drums.channels {
            let a = stft.analyze(ch)
            let spec = Spectrogram(re: a.re, im: a.im, frames: a.frames, bins: stft.bins, length: ch.count)
            let (hm, pm) = HPSS(harmonicKernel: 17, percussiveKernel: 17).masks(magnitude: spec.magnitude(), frames: spec.frames, bins: spec.bins)
            var keep = pm, move = hm
            for f in 0..<spec.frames {
                for b in 0..<spec.bins {
                    let i = f * spec.bins + b
                    let hz = Float(b) * binHz
                    // Low tonal content (kick / tom bodies) stays in the drums.
                    let low: Float = hz <= 200 ? 1 : (hz >= 400 ? 0 : (400 - hz) / 200)
                    keep[i] = pm[i] + hm[i] * low
                    move[i] = hm[i] * (1 - low)
                }
            }
            let k = spec.masked(keep), m = spec.masked(move)
            clean.append(stft.synthesize(re: k.re, im: k.im, frames: k.frames, length: ch.count))
            tonal.append(stft.synthesize(re: m.re, im: m.im, frames: m.frames, length: ch.count))
        }
        return (AudioData(channels: clean, sampleRate: drums.sampleRate),
                AudioData(channels: tonal, sampleRate: drums.sampleRate))
    }

    static func add(_ a: AudioData, _ b: AudioData) -> AudioData {
        var chans = a.channels
        for c in chans.indices where c < b.channels.count {
            let n = min(chans[c].count, b.channels[c].count)
            for i in 0..<n { chans[c][i] += b.channels[c][i] }
        }
        return AudioData(channels: chans, sampleRate: a.sampleRate)
    }
}
