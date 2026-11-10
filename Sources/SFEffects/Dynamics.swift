import Foundation
import SFCore

/// Feed-forward stereo-linked compressor with soft knee (log-domain detector).
public final class Compressor: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("threshold", "Threshold", min: -60, max: 0, default: -18, unit: .decibels),
        ParameterSpec("ratio", "Ratio", min: 1, max: 20, default: 4, unit: .ratio),
        ParameterSpec("attack", "Attack", min: 0.1, max: 200, default: 10, unit: .milliseconds, log: true),
        ParameterSpec("release", "Release", min: 5, max: 2000, default: 120, unit: .milliseconds, log: true),
        ParameterSpec("knee", "Knee", min: 0, max: 24, default: 6, unit: .decibels),
        ParameterSpec("makeup", "Makeup", min: 0, max: 36, default: 0, unit: .decibels),
        ParameterSpec("sidechainHPF", "Sidechain HPF", min: 20, max: 500, default: 20, unit: .hertz, log: true),
    ]
    private var envDB: Float = 0
    private var scL = Biquad(), scR = Biquad()
    private var lastHPF: Float = -1

    public init() { super.init(typeID: "compressor", name: "Compressor", specs: Self.specs) }
    public override func reset() { envDB = 0; scL.reset(); scR.reset() }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let thr = p(0), ratio = p(1), knee = p(4), makeup = p(5), hpf = p(6)
        if hpf != lastHPF {
            let c = BiquadCoefficients.make(.highpass, freq: hpf, q: 0.707, sampleRate: fs)
            scL.c = c; scR.c = c; lastHPF = hpf
        }
        let att = onePoleCoef(seconds: p(2) / 1000, sampleRate: fs)
        let rel = onePoleCoef(seconds: p(3) / 1000, sampleRate: fs)
        let slope = 1 - 1 / ratio
        var maxGR: Float = 0
        for i in 0..<frameCount {
            let x = max(abs(scL.process(left[i])), abs(scR.process(right[i])))
            let xdb = gainToDb(x)
            let over = xdb - thr
            var gr: Float = 0   // positive dB of reduction
            if knee > 0 && abs(over) <= knee / 2 {
                let t = over + knee / 2
                gr = slope * t * t / (2 * knee)
            } else if over > 0 {
                gr = slope * over
            }
            let c = gr > envDB ? att : rel
            envDB = gr + c * (envDB - gr)
            let g = dbToGain(makeup - envDB)
            left[i] *= g; right[i] *= g
            maxGR = max(maxGR, envDB)
        }
        meter.value = maxGR
    }
}

/// Look-ahead brickwall-style peak limiter.
public final class Limiter: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("input", "Input Gain", min: 0, max: 24, default: 0, unit: .decibels),
        ParameterSpec("ceiling", "Ceiling", min: -12, max: 0, default: -0.3, unit: .decibels),
        ParameterSpec("release", "Release", min: 1, max: 1000, default: 60, unit: .milliseconds, log: true),
    ]
    private var delayL = DelayLine(maxDelaySamples: 512), delayR = DelayLine(maxDelaySamples: 512)
    private var window: [Float] = []
    private var winPos = 0
    private var env: Float = 1
    private var lookahead = 64

    public init() { super.init(typeID: "limiter", name: "Limiter", specs: Self.specs) }
    public override var latencySamples: Int { lookahead }

    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        lookahead = max(16, min(480, Int(sampleRate * 0.0015)))
        window = [Float](repeating: 1, count: lookahead)
        delayL = DelayLine(maxDelaySamples: lookahead + 4); delayR = DelayLine(maxDelaySamples: lookahead + 4)
        env = 1
    }
    public override func reset() { delayL.clear(); delayR.clear(); env = 1; for i in 0..<window.count { window[i] = 1 } }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !window.isEmpty else { return }
        let inG = dbToGain(p(0)), ceil = dbToGain(p(1))
        let rel = onePoleCoef(seconds: p(2) / 1000, sampleRate: fs)
        let att = onePoleCoef(seconds: Float(lookahead) / fs / 5, sampleRate: fs)
        var minEnv: Float = 1
        for i in 0..<frameCount {
            let l = left[i] * inG, r = right[i] * inG
            let pk = max(abs(l), abs(r))
            window[winPos] = pk > ceil ? ceil / pk : 1
            winPos = (winPos + 1) % lookahead
            var target: Float = 1
            for w in window where w < target { target = w }
            env = target < env ? target + att * (env - target) : target + rel * (env - target)
            delayL.write(l); delayR.write(r)
            let g = env
            left[i] = clampf(delayL.read(lookahead) * g, -ceil, ceil)
            right[i] = clampf(delayR.read(lookahead) * g, -ceil, ceil)
            minEnv = min(minEnv, g)
        }
        meter.value = -gainToDb(minEnv)
    }
}

/// Noise gate / expander with hold and range.
public final class Gate: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("threshold", "Threshold", min: -90, max: 0, default: -50, unit: .decibels),
        ParameterSpec("attack", "Attack", min: 0.05, max: 50, default: 0.5, unit: .milliseconds, log: true),
        ParameterSpec("hold", "Hold", min: 0, max: 500, default: 30, unit: .milliseconds),
        ParameterSpec("release", "Release", min: 5, max: 2000, default: 100, unit: .milliseconds, log: true),
        ParameterSpec("range", "Range", min: -90, max: 0, default: -80, unit: .decibels),
    ]
    private var det = EnvelopeFollower()
    private var gain: Float = 0
    private var holdCounter = 0

    public init() { super.init(typeID: "gate", name: "Noise Gate", specs: Self.specs) }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        det.set(attackMs: 0.1, releaseMs: 20, sampleRate: fs)
    }
    public override func reset() { det.reset(); gain = 0; holdCounter = 0 }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let open = dbToGain(p(0)), close = dbToGain(p(0) - 4)   // 4 dB hysteresis
        let floor = dbToGain(p(4))
        let att = onePoleCoef(seconds: p(1) / 1000, sampleRate: fs)
        let rel = onePoleCoef(seconds: p(3) / 1000, sampleRate: fs)
        let holdSamples = Int(p(2) / 1000 * fs)
        for i in 0..<frameCount {
            let e = det.process(max(abs(left[i]), abs(right[i])))
            var target: Float
            if e > open { holdCounter = holdSamples; target = 1 }
            else if holdCounter > 0 { holdCounter -= 1; target = 1 }
            else if e < close { target = floor }
            else { target = gain > 0.5 ? 1 : floor }
            gain = target > gain ? target + att * (gain - target) : target + rel * (gain - target)
            left[i] *= gain; right[i] *= gain
        }
        meter.value = -gainToDb(max(gain, 1e-6))
    }
}

/// Gain / stereo width / polarity utility.
public final class Utility: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("gain", "Gain", min: -48, max: 24, default: 0, unit: .decibels),
        ParameterSpec("width", "Width", min: 0, max: 2, default: 1, unit: .percent),
        .toggle("invertL", "Invert L"), .toggle("invertR", "Invert R"),
        .toggle("mono", "Mono"),
    ]
    private var g = Smoothed(1)
    public init() { super.init(typeID: "utility", name: "Utility", specs: Self.specs) }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        g.setTarget(dbToGain(p(0)), rampSamples: frameCount)
        let width = p(4) >= 0.5 ? 0 : p(1)
        let sl: Float = p(2) >= 0.5 ? -1 : 1, sr: Float = p(3) >= 0.5 ? -1 : 1
        for i in 0..<frameCount {
            let gg = g.next()
            let l = left[i] * sl, r = right[i] * sr
            let m = (l + r) * 0.5, s = (l - r) * 0.5 * width
            left[i] = (m + s) * gg; right[i] = (m - s) * gg
        }
    }
}
