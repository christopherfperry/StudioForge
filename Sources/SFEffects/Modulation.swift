import Foundation
import SFCore

/// Multi-voice stereo chorus.
public final class Chorus: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("rate", "Rate", min: 0.05, max: 8, default: 0.8, log: true),
        ParameterSpec("depth", "Depth", min: 0, max: 15, default: 4, unit: .milliseconds),
        ParameterSpec("delay", "Delay", min: 2, max: 40, default: 12, unit: .milliseconds),
        ParameterSpec("voices", "Voices", min: 1, max: 4, default: 2),
        ParameterSpec("feedback", "Feedback", min: 0, max: 0.9, default: 0.1, unit: .percent),
        ParameterSpec("spread", "Stereo Spread", min: 0, max: 1, default: 0.8, unit: .percent),
        ParameterSpec("wet", "Wet", min: 0, max: 1, default: 0.5, unit: .percent),
    ]
    private var dl = DelayLine(maxDelaySamples: 4096), dr = DelayLine(maxDelaySamples: 4096)
    private var lfos = (0..<4).map { LFO(phase: Float($0) * 0.25) }
    private var fbL: Float = 0, fbR: Float = 0
    public init() { super.init(typeID: "chorus", name: "Chorus", specs: Self.specs) }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        let n = Int(sampleRate * 0.06) + 8
        dl = DelayLine(maxDelaySamples: n); dr = DelayLine(maxDelaySamples: n)
    }
    public override func reset() { dl.clear(); dr.clear(); fbL = 0; fbR = 0 }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let rate = p(0), depth = p(1) / 1000 * fs, base = p(2) / 1000 * fs
        let voices = max(1, min(4, pi(3))), fb = p(4), spread = p(5), wet = p(6)
        let norm = 1 / Float(voices)
        for i in 0..<frameCount {
            let xl = left[i], xr = right[i]
            dl.write(xl + fbL * fb); dr.write(xr + fbR * fb)
            var wl: Float = 0, wr: Float = 0
            for v in 0..<voices {
                let m = lfos[v].next(rate: rate * (1 + Float(v) * 0.13), sampleRate: fs)
                let dL = base + depth * (0.5 + 0.5 * m)
                let dR = base + depth * (0.5 + 0.5 * (spread > 0 ? -m * spread + m * (1 - spread) : m))
                wl += dl.read(cubic: dL); wr += dr.read(cubic: dR)
            }
            wl *= norm; wr *= norm
            fbL = wl; fbR = wr
            left[i] = xl * (1 - wet * 0.5) + wl * wet
            right[i] = xr * (1 - wet * 0.5) + wr * wet
        }
    }
}

/// Classic through-zero-ish flanger with feedback.
public final class Flanger: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("rate", "Rate", min: 0.02, max: 5, default: 0.25, log: true),
        ParameterSpec("depth", "Depth", min: 0, max: 1, default: 0.7, unit: .percent),
        ParameterSpec("delay", "Delay", min: 0.1, max: 10, default: 2, unit: .milliseconds),
        ParameterSpec("feedback", "Feedback", min: -0.95, max: 0.95, default: 0.6),
        ParameterSpec("wet", "Wet", min: 0, max: 1, default: 0.5, unit: .percent),
    ]
    private var dl = DelayLine(maxDelaySamples: 2048), dr = DelayLine(maxDelaySamples: 2048)
    private var lfoL = LFO(phase: 0), lfoR = LFO(phase: 0.25)
    private var fbL: Float = 0, fbR: Float = 0
    public init() { super.init(typeID: "flanger", name: "Flanger", specs: Self.specs) }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        dl = DelayLine(maxDelaySamples: Int(sampleRate * 0.025)); dr = DelayLine(maxDelaySamples: Int(sampleRate * 0.025))
    }
    public override func reset() { dl.clear(); dr.clear(); fbL = 0; fbR = 0 }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let base = p(2) / 1000 * fs, depth = p(1), fb = p(3), wet = p(4)
        for i in 0..<frameCount {
            let ml = 0.5 + 0.5 * lfoL.next(rate: p(0), sampleRate: fs, shape: .triangle)
            let mr = 0.5 + 0.5 * lfoR.next(rate: p(0), sampleRate: fs, shape: .triangle)
            dl.write(left[i] + fastTanh(fbL * fb)); dr.write(right[i] + fastTanh(fbR * fb))
            let yl = dl.read(cubic: 2 + base * (0.05 + depth * ml)), yr = dr.read(cubic: 2 + base * (0.05 + depth * mr))
            fbL = yl; fbR = yr
            left[i] = left[i] * (1 - wet * 0.5) + yl * wet
            right[i] = right[i] * (1 - wet * 0.5) + yr * wet
        }
    }
}

/// Multi-stage allpass phaser.
public final class Phaser: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("rate", "Rate", min: 0.02, max: 8, default: 0.4, log: true),
        ParameterSpec("depth", "Depth", min: 0, max: 1, default: 0.8, unit: .percent),
        ParameterSpec("center", "Center", min: 100, max: 4000, default: 800, unit: .hertz, log: true),
        ParameterSpec("stages", "Stages", min: 2, max: 12, default: 6),
        ParameterSpec("feedback", "Feedback", min: -0.9, max: 0.9, default: 0.5),
        ParameterSpec("wet", "Wet", min: 0, max: 1, default: 0.5, unit: .percent),
    ]
    private var apL = [FirstOrderAllpass](repeating: FirstOrderAllpass(), count: 12)
    private var apR = [FirstOrderAllpass](repeating: FirstOrderAllpass(), count: 12)
    private var lfo = LFO()
    private var fbL: Float = 0, fbR: Float = 0
    public init() { super.init(typeID: "phaser", name: "Phaser", specs: Self.specs) }
    public override func reset() { for i in 0..<12 { apL[i].reset(); apR[i].reset() }; fbL = 0; fbR = 0 }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let stages = max(2, min(12, pi(3))), fb = p(4), wet = p(5), depth = p(1), center = p(2)
        for i in 0..<frameCount {
            let m = lfo.next(rate: p(0), sampleRate: fs)
            let fcL = center * powf(2, m * depth * 2), fcR = center * powf(2, -m * depth * 2)
            let tl = tanf(Float.pi * min(fcL, fs * 0.45) / fs), tr = tanf(Float.pi * min(fcR, fs * 0.45) / fs)
            let aL = (tl - 1) / (tl + 1), aR = (tr - 1) / (tr + 1)
            var yl = left[i] + fbL * fb, yr = right[i] + fbR * fb
            for s in 0..<stages { yl = apL[s].process(yl, a: aL); yr = apR[s].process(yr, a: aR) }
            fbL = yl; fbR = yr
            left[i] = left[i] * (1 - wet * 0.5) + yl * wet
            right[i] = right[i] * (1 - wet * 0.5) + yr * wet
        }
    }
}

/// Tremolo / auto-pan.
public final class Tremolo: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("rate", "Rate", min: 0.1, max: 20, default: 5, log: true),
        ParameterSpec("depth", "Depth", min: 0, max: 1, default: 0.6, unit: .percent),
        .choice("shape", "Shape", ["Sine", "Triangle", "Square"]),
        ParameterSpec("stereo", "Stereo Phase (Pan)", min: 0, max: 1, default: 0, unit: .percent),
    ]
    private var lfoL = LFO(), lfoR = LFO()
    public init() { super.init(typeID: "tremolo", name: "Tremolo / Auto-Pan", specs: Self.specs) }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let shape = LFO.Shape(rawValue: pi(2)) ?? .sine, depth = p(1)
        lfoR.phase = lfoL.phase + p(3) * 0.5
        if lfoR.phase >= 1 { lfoR.phase -= 1 }
        for i in 0..<frameCount {
            let ml = lfoL.next(rate: p(0), sampleRate: fs, shape: shape)
            let mr = lfoR.next(rate: p(0), sampleRate: fs, shape: shape)
            left[i] *= 1 - depth * (0.5 + 0.5 * ml)
            right[i] *= 1 - depth * (0.5 + 0.5 * mr)
        }
    }
}

/// Ring modulator with optional frequency LFO.
public final class RingModulator: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("frequency", "Frequency", min: 1, max: 5000, default: 220, unit: .hertz, log: true),
        ParameterSpec("lfoRate", "LFO Rate", min: 0.01, max: 10, default: 0.2, log: true),
        ParameterSpec("lfoDepth", "LFO Depth (oct)", min: 0, max: 3, default: 0),
        ParameterSpec("wet", "Wet", min: 0, max: 1, default: 0.7, unit: .percent),
    ]
    private var phase: Float = 0
    private var lfo = LFO()
    public init() { super.init(typeID: "ringmod", name: "Ring Modulator", specs: Self.specs) }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let wet = p(3)
        for i in 0..<frameCount {
            let f = p(0) * powf(2, lfo.next(rate: p(1), sampleRate: fs) * p(2))
            let c = sinf(twoPi * phase)
            phase += f / fs; if phase >= 1 { phase -= 1 }
            left[i] = left[i] * (1 - wet) + left[i] * c * wet
            right[i] = right[i] * (1 - wet) + right[i] * c * wet
        }
    }
}

/// Vocal/guitar doubler: two short, slowly-modulated, slightly-detuned delays panned wide.
public final class Doubler: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("delayL", "Delay L", min: 5, max: 60, default: 18, unit: .milliseconds),
        ParameterSpec("delayR", "Delay R", min: 5, max: 60, default: 27, unit: .milliseconds),
        ParameterSpec("detune", "Detune", min: 0, max: 30, default: 8, unit: .cents),
        ParameterSpec("width", "Width", min: 0, max: 1, default: 0.9, unit: .percent),
        ParameterSpec("wet", "Double Level", min: 0, max: 1, default: 0.6, unit: .percent),
    ]
    private var dl = DelayLine(maxDelaySamples: 8192), dr = DelayLine(maxDelaySamples: 8192)
    private var lfoL = LFO(phase: 0), lfoR = LFO(phase: 0.4)
    public init() { super.init(typeID: "doubler", name: "Doubler", specs: Self.specs) }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        dl = DelayLine(maxDelaySamples: Int(sampleRate * 0.1)); dr = DelayLine(maxDelaySamples: Int(sampleRate * 0.1))
    }
    public override func reset() { dl.clear(); dr.clear() }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        // Pitch deviation from a sinusoidally modulated delay: depth(samples) = cents-ratio / (2π f)
        let rate: Float = 0.35
        let ratio = semitonesToRatio(p(2) / 100) - 1
        let depth = ratio * fs / (twoPi * rate)
        let width = p(3), wet = p(4)
        for i in 0..<frameCount {
            let m = (left[i] + right[i]) * 0.5
            dl.write(m); dr.write(m)
            let a = dl.read(cubic: p(0) / 1000 * fs + depth * (1 + lfoL.next(rate: rate, sampleRate: fs)))
            let b = dr.read(cubic: p(1) / 1000 * fs + depth * (1 + lfoR.next(rate: rate * 1.1, sampleRate: fs)))
            let l = a * (0.5 + 0.5 * width) + b * (0.5 - 0.5 * width)
            let r = b * (0.5 + 0.5 * width) + a * (0.5 - 0.5 * width)
            left[i] += l * wet; right[i] += r * wet
        }
    }
}
