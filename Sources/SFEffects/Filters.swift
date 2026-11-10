import Foundation
import SFCore

/// 7-section parametric EQ: low cut, low shelf, 3 peaks, high shelf, high cut.
public final class ParametricEQ: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("lowCut", "Low Cut", min: 10, max: 1000, default: 10, unit: .hertz, log: true),
        ParameterSpec("lowShelfFreq", "Low Shelf Freq", min: 30, max: 600, default: 100, unit: .hertz, log: true),
        ParameterSpec("lowShelfGain", "Low Shelf Gain", min: -18, max: 18, default: 0, unit: .decibels),
        ParameterSpec("peak1Freq", "Low-Mid Freq", min: 60, max: 2000, default: 300, unit: .hertz, log: true),
        ParameterSpec("peak1Gain", "Low-Mid Gain", min: -18, max: 18, default: 0, unit: .decibels),
        ParameterSpec("peak1Q", "Low-Mid Q", min: 0.2, max: 10, default: 1, log: true),
        ParameterSpec("peak2Freq", "Mid Freq", min: 200, max: 6000, default: 1000, unit: .hertz, log: true),
        ParameterSpec("peak2Gain", "Mid Gain", min: -18, max: 18, default: 0, unit: .decibels),
        ParameterSpec("peak2Q", "Mid Q", min: 0.2, max: 10, default: 1, log: true),
        ParameterSpec("peak3Freq", "High-Mid Freq", min: 1000, max: 16000, default: 3500, unit: .hertz, log: true),
        ParameterSpec("peak3Gain", "High-Mid Gain", min: -18, max: 18, default: 0, unit: .decibels),
        ParameterSpec("peak3Q", "High-Mid Q", min: 0.2, max: 10, default: 1, log: true),
        ParameterSpec("highShelfFreq", "High Shelf Freq", min: 1500, max: 18000, default: 8000, unit: .hertz, log: true),
        ParameterSpec("highShelfGain", "High Shelf Gain", min: -18, max: 18, default: 0, unit: .decibels),
        ParameterSpec("highCut", "High Cut", min: 1000, max: 22000, default: 22000, unit: .hertz, log: true),
        ParameterSpec("output", "Output", min: -24, max: 24, default: 0, unit: .decibels),
    ]
    private var bandsL = [Biquad](repeating: Biquad(), count: 7)
    private var bandsR = [Biquad](repeating: Biquad(), count: 7)
    private var active = [Bool](repeating: false, count: 7)
    private var cached: [Float] = [Float](repeating: -9999, count: 16)

    public init() { super.init(typeID: "eq", name: "Parametric EQ", specs: Self.specs) }
    public override func reset() { for i in 0..<7 { bandsL[i].reset(); bandsR[i].reset() } }

    /// Coefficients for each active band (also used to draw the EQ curve in the UI).
    public func coefficients() -> [BiquadCoefficients?] {
        let sr = fs
        let nyq = sr * 0.45
        return [
            p(0) > 12 ? .make(.highpass, freq: p(0), q: 0.707, sampleRate: sr) : nil,
            abs(p(2)) > 0.05 ? .make(.lowShelf, freq: p(1), q: 0.707, gainDB: p(2), sampleRate: sr) : nil,
            abs(p(4)) > 0.05 ? .make(.peak, freq: p(3), q: p(5), gainDB: p(4), sampleRate: sr) : nil,
            abs(p(7)) > 0.05 ? .make(.peak, freq: p(6), q: p(8), gainDB: p(7), sampleRate: sr) : nil,
            abs(p(10)) > 0.05 ? .make(.peak, freq: min(p(9), nyq), q: p(11), gainDB: p(10), sampleRate: sr) : nil,
            abs(p(13)) > 0.05 ? .make(.highShelf, freq: min(p(12), nyq), q: 0.707, gainDB: p(13), sampleRate: sr) : nil,
            p(14) < min(21000, nyq) ? .make(.lowpass, freq: p(14), q: 0.707, sampleRate: sr) : nil,
        ]
    }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Allocation-free change detection against a pre-sized cache.
        var changed = cached.count != parameters.all.count
        if !changed {
            for (i, prm) in parameters.all.enumerated() where prm.value != cached[i] { changed = true; break }
        }
        if changed {
            if cached.count != parameters.all.count { cached = [Float](repeating: 0, count: parameters.all.count) }
            for (i, prm) in parameters.all.enumerated() { cached[i] = prm.value }
            let cs = coefficients()
            for i in 0..<7 {
                if let c = cs[i] { bandsL[i].c = c; bandsR[i].c = c; active[i] = true } else { active[i] = false }
            }
        }
        for b in 0..<7 where active[b] {
            bandsL[b].process(left, count: frameCount)
            bandsR[b].process(right, count: frameCount)
        }
        let out = dbToGain(p(15))
        if out != 1 { BufferOps.scale(left, frameCount, out); BufferOps.scale(right, frameCount, out) }
    }
}

/// Multimode resonant filter with LFO sweep (industrial filter sweeps, telephone/megaphone voices).
public final class FilterEffect: EffectBase {
    public static let specs: [ParameterSpec] = [
        .choice("mode", "Mode", ["Low Pass", "High Pass", "Band Pass", "Notch", "Low Pass 24"]),
        ParameterSpec("cutoff", "Cutoff", min: 20, max: 20000, default: 2000, unit: .hertz, log: true),
        ParameterSpec("resonance", "Resonance", min: 0.5, max: 12, default: 0.9, log: true),
        ParameterSpec("drive", "Drive", min: 0, max: 24, default: 0, unit: .decibels),
        ParameterSpec("lfoRate", "LFO Rate", min: 0.01, max: 20, default: 0.5, log: true),
        ParameterSpec("lfoDepth", "LFO Depth (oct)", min: 0, max: 5, default: 0),
    ]
    private var fl = SVFilter(), fr = SVFilter(), fl2 = SVFilter(), fr2 = SVFilter()
    private var lfo = LFO()
    public init() { super.init(typeID: "filter", name: "Filter", specs: Self.specs) }
    public override func reset() { fl.reset(); fr.reset(); fl2.reset(); fr2.reset() }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let mode = pi(0), base = p(1), q = p(2), drive = dbToGain(p(3)), rate = p(4), depth = p(5)
        var i = 0
        while i < frameCount {
            let n = min(16, frameCount - i)
            var lf: Float = 0
            for _ in 0..<n { lf = lfo.next(rate: rate, sampleRate: fs) }
            let fc = base * powf(2, lf * depth)
            fl.set(cutoff: fc, resonance: q, sampleRate: fs); fr.set(cutoff: fc, resonance: q, sampleRate: fs)
            if mode == 4 { fl2.set(cutoff: fc, resonance: 0.707, sampleRate: fs); fr2.set(cutoff: fc, resonance: 0.707, sampleRate: fs) }
            for k in i..<(i + n) {
                var l = left[k], r = right[k]
                if drive > 1.001 { l = fastTanh(l * drive); r = fastTanh(r * drive) }
                switch mode {
                case 1: l = fl.highpass(l); r = fr.highpass(r)
                case 2: l = fl.bandpass(l); r = fr.bandpass(r)
                case 3: l = fl.notch(l); r = fr.notch(r)
                case 4: l = fl2.lowpass(fl.lowpass(l)); r = fr2.lowpass(fr.lowpass(r))
                default: l = fl.lowpass(l); r = fr.lowpass(r)
                }
                left[k] = l; right[k] = r
            }
            i += n
        }
    }
}

/// Envelope- or LFO-driven wah.
public final class AutoWah: EffectBase {
    public static let specs: [ParameterSpec] = [
        .choice("mode", "Mode", ["Envelope", "LFO"]),
        ParameterSpec("sensitivity", "Sensitivity", min: 0, max: 1, default: 0.6, unit: .percent),
        ParameterSpec("minFreq", "Min Freq", min: 100, max: 1500, default: 350, unit: .hertz, log: true),
        ParameterSpec("maxFreq", "Max Freq", min: 800, max: 6000, default: 2400, unit: .hertz, log: true),
        ParameterSpec("q", "Q", min: 1, max: 15, default: 5, log: true),
        ParameterSpec("rate", "LFO Rate", min: 0.05, max: 10, default: 1.5, log: true),
        ParameterSpec("release", "Release", min: 10, max: 1000, default: 120, unit: .milliseconds, log: true),
    ]
    private var fl = SVFilter(), fr = SVFilter()
    private var env = EnvelopeFollower()
    private var lfo = LFO()
    public init() { super.init(typeID: "autowah", name: "Auto-Wah", specs: Self.specs) }
    public override func reset() { fl.reset(); fr.reset(); env.reset() }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        env.set(attackMs: 3, releaseMs: p(6), sampleRate: fs)
        let lo = p(2), hi = max(p(3), lo + 10), q = p(4), sens = p(1)
        var i = 0
        while i < frameCount {
            let n = min(16, frameCount - i)
            var ctl: Float = 0
            if pi(0) == 0 {
                for k in i..<(i + n) { ctl = env.process((left[k] + right[k]) * 0.5) }
                ctl = min(1, ctl * (1 + sens * 30))
            } else {
                for _ in 0..<n { ctl = lfo.next(rate: p(5), sampleRate: fs) }
                ctl = 0.5 + 0.5 * ctl
            }
            let fc = lo * powf(hi / lo, ctl)
            fl.set(cutoff: fc, resonance: q, sampleRate: fs); fr.set(cutoff: fc, resonance: q, sampleRate: fs)
            for k in i..<(i + n) {
                left[k] = fl.bandpass(left[k]) * 1.6 + left[k] * 0.1
                right[k] = fr.bandpass(right[k]) * 1.6 + right[k] * 0.1
            }
            i += n
        }
    }
}

/// Vowel formant filter (A-E-I-O-U morph) — talk-box / vocoder-ish colours and formant shifting.
public final class FormantFilter: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("vowel", "Vowel (A-E-I-O-U)", min: 0, max: 4, default: 0),
        ParameterSpec("shift", "Formant Shift", min: -12, max: 12, default: 0, unit: .semitones),
        ParameterSpec("q", "Resonance", min: 2, max: 30, default: 10, log: true),
        ParameterSpec("lfoRate", "Morph Rate", min: 0, max: 8, default: 0),
        ParameterSpec("lfoDepth", "Morph Depth", min: 0, max: 4, default: 0),
    ]
    // Formant centre frequencies (Hz) and gains for A, E, I, O, U (male voice approximations).
    private static let f: [[Float]] = [[730, 1090, 2440], [530, 1840, 2480], [270, 2290, 3010], [570, 840, 2410], [300, 870, 2240]]
    private static let g: [[Float]] = [[1, 0.5, 0.25], [1, 0.45, 0.3], [1, 0.3, 0.25], [1, 0.45, 0.2], [1, 0.35, 0.15]]
    private var filtersL = [SVFilter](repeating: SVFilter(), count: 3)
    private var filtersR = [SVFilter](repeating: SVFilter(), count: 3)
    private var lfo = LFO()
    public init() { super.init(typeID: "formant", name: "Formant Filter", specs: Self.specs) }
    public override func reset() { for i in 0..<3 { filtersL[i].reset(); filtersR[i].reset() } }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let shift = semitonesToRatio(p(1)), q = p(2)
        var i = 0
        var gains: (Float, Float, Float) = (1, 0.5, 0.25)
        while i < frameCount {
            let n = min(32, frameCount - i)
            var l: Float = 0
            for _ in 0..<n { l = lfo.next(rate: max(p(3), 0.0001), sampleRate: fs) }
            let v = clampf(p(0) + l * p(4), 0, 4)
            let a = min(3, Int(v)), t = v - Float(a), b = min(4, a + 1)
            for k in 0..<3 {
                let fc = lerpf(Self.f[a][k], Self.f[b][k], t) * shift
                filtersL[k].set(cutoff: fc, resonance: q, sampleRate: fs)
                filtersR[k].set(cutoff: fc, resonance: q, sampleRate: fs)
            }
            gains = (lerpf(Self.g[a][0], Self.g[b][0], t), lerpf(Self.g[a][1], Self.g[b][1], t), lerpf(Self.g[a][2], Self.g[b][2], t))
            for k in i..<(i + n) {
                let xl = left[k], xr = right[k]
                left[k] = (filtersL[0].bandpass(xl) * gains.0 + filtersL[1].bandpass(xl) * gains.1 + filtersL[2].bandpass(xl) * gains.2) * 2.5
                right[k] = (filtersR[0].bandpass(xr) * gains.0 + filtersR[1].bandpass(xr) * gains.1 + filtersR[2].bandpass(xr) * gains.2) * 2.5
            }
            i += n
        }
    }
}
