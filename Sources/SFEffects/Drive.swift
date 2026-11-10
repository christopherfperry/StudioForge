import Foundation
import SFCore

public enum Shapers {
    @inline(__always) public static func shape(_ x: Float, mode: Int, bias: Float) -> Float {
        switch mode {
        case 0: // Overdrive: asymmetric soft clip
            let y = x + bias
            return y >= 0 ? fastTanh(y) : fastTanh(y * 0.8) / 0.8 * 0.9
        case 1: // Distortion: atan-like hard-ish curve
            return fastTanh(x * 1.5 + bias) * 0.95
        case 2: // Fuzz: hard asymmetric clip with gating character
            let y = x + bias * 2
            return y > 0 ? min(y, 0.7) / 0.7 : max(y, -0.35) / 0.35 * 0.85
        case 3: // Tube: exponential asymmetric
            let y = x + bias
            return y >= 0 ? (1 - expf(-y)) : -(1 - expf(y * 1.2)) / 1.2
        case 4: // Hard clip
            return clampf(x + bias, -1, 1)
        case 5: // Foldback
            var y = x + bias
            for _ in 0..<4 where abs(y) > 1 { y = y > 1 ? 2 - y : -2 - y }
            return clampf(y, -1, 1)
        case 6: // Rectify (octave-up fuzz)
            return fastTanh(abs(x + bias) * 2 - 0.5)
        default: // Tape saturation
            return fastTanh(x + bias * x * x)
        }
    }
}

/// Multi-mode drive: overdrive, distortion, fuzz, tube, hard clip, foldback, rectifier, tape.
public final class Distortion: EffectBase {
    public static let modes = ["Overdrive", "Distortion", "Fuzz", "Tube", "Hard Clip", "Foldback", "Rectifier", "Tape"]
    public static let specs: [ParameterSpec] = [
        .choice("mode", "Mode", modes),
        ParameterSpec("drive", "Drive", min: 0, max: 60, default: 18, unit: .decibels),
        ParameterSpec("tone", "Tone", min: 400, max: 16000, default: 5000, unit: .hertz, log: true),
        ParameterSpec("preHPF", "Tight (Pre HPF)", min: 20, max: 1200, default: 80, unit: .hertz, log: true),
        ParameterSpec("bias", "Bias", min: -0.5, max: 0.5, default: 0),
        ParameterSpec("output", "Output", min: -40, max: 12, default: -6, unit: .decibels),
    ]
    private var hpL = Biquad(), hpR = Biquad(), lpL = Biquad(), lpR = Biquad(), lp2L = Biquad(), lp2R = Biquad()
    private var dcL = DCBlocker(), dcR = DCBlocker()
    private var lastTone: Float = -1, lastHP: Float = -1

    public init() { super.init(typeID: "distortion", name: "Distortion", specs: Self.specs) }
    public override func reset() { hpL.reset(); hpR.reset(); lpL.reset(); lpR.reset(); lp2L.reset(); lp2R.reset() }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        if p(2) != lastTone {
            lastTone = p(2)
            let c = BiquadCoefficients.make(.lowpass, freq: lastTone, q: 0.707, sampleRate: fs)
            lpL.c = c; lpR.c = c; lp2L.c = c; lp2R.c = c
        }
        if p(3) != lastHP {
            lastHP = p(3)
            let c = BiquadCoefficients.make(.highpass, freq: lastHP, q: 0.707, sampleRate: fs)
            hpL.c = c; hpR.c = c
        }
        let mode = pi(0), drive = dbToGain(p(1)), bias = p(4), out = dbToGain(p(5))
        for i in 0..<frameCount {
            var l = hpL.process(left[i]) * drive, r = hpR.process(right[i]) * drive
            l = Shapers.shape(l, mode: mode, bias: bias)
            r = Shapers.shape(r, mode: mode, bias: bias)
            left[i] = lp2L.process(lpL.process(dcL.process(l))) * out
            right[i] = lp2R.process(lpR.process(dcR.process(r))) * out
        }
    }
}

/// Bit depth and sample-rate reduction.
public final class Bitcrusher: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("bits", "Bits", min: 1, max: 16, default: 8),
        ParameterSpec("downsample", "Downsample", min: 1, max: 64, default: 4, log: true),
        ParameterSpec("output", "Output", min: -24, max: 12, default: 0, unit: .decibels),
    ]
    private var holdL: Float = 0, holdR: Float = 0, counter: Float = 0
    public init() { super.init(typeID: "bitcrusher", name: "Bitcrusher", specs: Self.specs) }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let levels = powf(2, p(0) - 1), ds = p(1), out = dbToGain(p(2))
        for i in 0..<frameCount {
            counter += 1
            if counter >= ds {
                counter -= ds
                holdL = (left[i] * levels).rounded() / levels
                holdR = (right[i] * levels).rounded() / levels
            }
            left[i] = holdL * out; right[i] = holdR * out
        }
    }
}

/// Static waveshaper with selectable transfer curves.
public final class Waveshaper: EffectBase {
    public static let specs: [ParameterSpec] = [
        .choice("curve", "Curve", ["Sine Fold", "Chebyshev 3", "Tanh", "Cubic", "Asymmetric"]),
        ParameterSpec("amount", "Amount", min: 0, max: 1, default: 0.5, unit: .percent),
        ParameterSpec("output", "Output", min: -24, max: 12, default: -3, unit: .decibels),
    ]
    private var dcL = DCBlocker(), dcR = DCBlocker()
    public init() { super.init(typeID: "waveshaper", name: "Waveshaper", specs: Self.specs) }
    @inline(__always) private func shape(_ x: Float, _ curve: Int, _ k: Float) -> Float {
        switch curve {
        case 0: return sinf(x * (1 + k * 6) * Float.pi / 2)
        case 1: let y = clampf(x, -1, 1); return lerpf(y, 4 * y * y * y - 3 * y, k)
        case 3: let y = clampf(x * (1 + k * 2), -1.5, 1.5); return y - y * y * y / 6.75 * 2
        case 4: return x >= 0 ? fastTanh(x * (1 + k * 8)) : fastTanh(x * (1 + k * 2))
        default: return fastTanh(x * (1 + k * 10))
        }
    }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let c = pi(0), k = p(1), out = dbToGain(p(2))
        for i in 0..<frameCount {
            left[i] = dcL.process(shape(left[i], c, k)) * out
            right[i] = dcR.process(shape(right[i], c, k)) * out
        }
    }
}

/// Guitar / bass amplifier model: tight HPF -> preamp stages -> tone stack -> power-amp sag.
public final class AmpSim: EffectBase {
    public static let models = ["Clean", "Crunch", "British Lead", "US High Gain", "Modern Metal", "Bass Amp", "Goth Clean", "Fuzz Stack"]
    public static let specs: [ParameterSpec] = [
        .choice("model", "Model", models, default: 2),
        ParameterSpec("gain", "Gain", min: 0, max: 10, default: 6),
        ParameterSpec("bass", "Bass", min: 0, max: 10, default: 5),
        ParameterSpec("mid", "Mid", min: 0, max: 10, default: 5),
        ParameterSpec("treble", "Treble", min: 0, max: 10, default: 6),
        ParameterSpec("presence", "Presence", min: 0, max: 10, default: 5),
        ParameterSpec("master", "Master", min: -40, max: 6, default: -12, unit: .decibels),
        ParameterSpec("sag", "Sag", min: 0, max: 1, default: 0.3, unit: .percent),
        ParameterSpec("tight", "Tight", min: 20, max: 400, default: 90, unit: .hertz, log: true),
    ]
    // Per model: stage-1 gain, stage-2 gain (0 = single stage), mid-hump freq, top cut, asymmetry
    private static let modelData: [(Float, Float, Float, Float, Float)] = [
        (2, 0, 700, 9000, 0.0), (8, 0, 800, 7000, 0.1), (14, 6, 750, 6500, 0.15), (20, 10, 600, 6000, 0.1),
        (26, 14, 900, 5500, 0.05), (4, 1.5, 500, 5000, 0.08), (3, 0, 900, 8000, 0.05), (30, 8, 1000, 4500, 0.3),
    ]
    private var tightL = Biquad(), tightR = Biquad()
    private var humpL = Biquad(), humpR = Biquad()
    private var interL = Biquad(), interR = Biquad()
    private var bassL = Biquad(), bassR = Biquad(), midL = Biquad(), midR = Biquad()
    private var trebL = Biquad(), trebR = Biquad(), presL = Biquad(), presR = Biquad()
    private var topL = Biquad(), topR = Biquad()
    private var dcL = DCBlocker(), dcR = DCBlocker()
    private var sagEnv: Float = 0
    private var cache: [Float] = [Float](repeating: -1, count: 9)

    public init() { super.init(typeID: "amp", name: "Amp Simulator", specs: Self.specs) }
    public override func reset() {
        tightL.reset(); tightR.reset(); humpL.reset(); humpR.reset(); interL.reset(); interR.reset()
        bassL.reset(); bassR.reset(); midL.reset(); midR.reset(); trebL.reset(); trebR.reset()
        presL.reset(); presR.reset(); topL.reset(); topR.reset(); sagEnv = 0
    }

    private func updateFilters() {
        let m = Self.modelData[min(pi(0), Self.modelData.count - 1)]
        let sr = fs
        func set(_ a: inout Biquad, _ b: inout Biquad, _ c: BiquadCoefficients) { a.c = c; b.c = c }
        set(&tightL, &tightR, .make(.highpass, freq: p(8), q: 0.707, sampleRate: sr))
        set(&humpL, &humpR, .make(.peak, freq: m.2, q: 0.8, gainDB: 6, sampleRate: sr))
        set(&interL, &interR, .make(.lowpass, freq: m.3 * 1.4, q: 0.6, sampleRate: sr))
        set(&bassL, &bassR, .make(.lowShelf, freq: 110, q: 0.7, gainDB: (p(2) - 5) * 2.4, sampleRate: sr))
        set(&midL, &midR, .make(.peak, freq: 650, q: 0.7, gainDB: (p(3) - 5) * 2.4, sampleRate: sr))
        set(&trebL, &trebR, .make(.highShelf, freq: 2800, q: 0.7, gainDB: (p(4) - 5) * 2.4, sampleRate: sr))
        set(&presL, &presR, .make(.peak, freq: 4500, q: 0.9, gainDB: (p(5) - 5) * 1.6, sampleRate: sr))
        set(&topL, &topR, .make(.lowpass, freq: m.3, q: 0.707, sampleRate: sr))
    }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        var changed = false
        for i in 0..<9 where cache[i] != p(i) { cache[i] = p(i); changed = true }
        if changed { updateFilters() }
        let m = Self.modelData[min(pi(0), Self.modelData.count - 1)]
        let g = p(1) / 10
        let g1 = 1 + m.0 * g * g * 4, g2 = m.1 > 0 ? 1 + m.1 * g * 3 : 0
        let asym = m.4, master = dbToGain(p(6)), sagAmt = p(7)
        let sagRel = onePoleCoef(seconds: 0.12, sampleRate: fs)
        let comp: Float = 1 / (0.6 + 0.4 * sqrtf(g1))
        for i in 0..<frameCount {
            var l = humpL.process(tightL.process(left[i])) * g1
            var r = humpR.process(tightR.process(right[i])) * g1
            l = fastTanh(l + asym * l * l); r = fastTanh(r + asym * r * r)
            if g2 > 0 {
                l = fastTanh(interL.process(l) * g2 - asym * 0.5)
                r = fastTanh(interR.process(r) * g2 - asym * 0.5)
            }
            l = presL.process(trebL.process(midL.process(bassL.process(l))))
            r = presR.process(trebR.process(midR.process(bassR.process(r))))
            let lvl = max(abs(l), abs(r))
            sagEnv = lvl > sagEnv ? lvl : lvl + sagRel * (sagEnv - lvl)
            let pg = 1.4 * (1 - sagAmt * 0.35 * min(sagEnv, 1.5))
            l = fastTanh(l * pg); r = fastTanh(r * pg)
            left[i] = topL.process(dcL.process(l)) * master * comp * 2
            right[i] = topR.process(dcR.process(r)) * master * comp * 2
        }
    }
}
