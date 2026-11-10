import Foundation
import SFCore

/// 8-line feedback delay network reverb with input diffusion, per-line damping, modulation and
/// a Householder feedback matrix. Different "rooms" are presets of this engine with distinct
/// default parameters (room, hall, chamber, plate, cathedral, ambient) plus special variants
/// (gated, shimmer, reverse) that subclass it.
public class FDNReverb: EffectBase {
    public enum Kind: String, CaseIterable {
        case room, hall, chamber, plate, cathedral, ambient, gated, shimmer, reverse
    }
    static func baseSpecs(size: Float, decay: Float, predelay: Float, damping: Float, diffusion: Float,
                          modulation: Float, wet: Float, lowCut: Float = 80) -> [ParameterSpec] {
        [
            ParameterSpec("size", "Size", min: 0.1, max: 1, default: size, unit: .percent),
            ParameterSpec("decay", "Decay", min: 0.1, max: 30, default: decay, unit: .seconds, log: true),
            ParameterSpec("predelay", "Pre-delay", min: 0, max: 250, default: predelay, unit: .milliseconds),
            ParameterSpec("damping", "Damping (HF)", min: 1000, max: 20000, default: damping, unit: .hertz, log: true),
            ParameterSpec("lowCut", "Low Cut", min: 20, max: 1000, default: lowCut, unit: .hertz, log: true),
            ParameterSpec("diffusion", "Diffusion", min: 0, max: 1, default: diffusion, unit: .percent),
            ParameterSpec("modulation", "Modulation", min: 0, max: 1, default: modulation, unit: .percent),
            ParameterSpec("width", "Width", min: 0, max: 1, default: 1, unit: .percent),
            ParameterSpec("wet", "Wet", min: 0, max: 1, default: wet, unit: .percent),
            ParameterSpec("dry", "Dry", min: 0, max: 1, default: 1, unit: .percent),
        ]
    }
    static let baseCount = 10
    private static let baseMs: [Float] = [29.7, 37.1, 41.1, 43.7, 53.3, 59.9, 67.1, 73.3]

    private var lines: [DelayLine] = []
    private var damp = [OnePole](repeating: OnePole(), count: 8)
    private var diffusers: [AllpassDiffuser] = []
    private var pre = DelayLine(maxDelaySamples: 16384)
    private var lowCutL = OnePole(), lowCutR = OnePole()
    private var lfo1 = LFO(phase: 0), lfo2 = LFO(phase: 0.33)
    private var lengths = [Float](repeating: 1000, count: 8)
    private var gains = [Float](repeating: 0.5, count: 8)
    private var state = [Float](repeating: 0, count: 8)
    private var cacheKey: (Float, Float, Float) = (-1, -1, -1)
    let kind: Kind

    init(kind: Kind, name: String, specs: [ParameterSpec]) {
        self.kind = kind
        super.init(typeID: "reverb.\(kind.rawValue)", name: name, specs: specs)
    }

    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        let maxLen = Int(Float(sampleRate) * 0.08 * 2.2) + 64
        lines = (0..<8).map { _ in DelayLine(maxDelaySamples: maxLen) }
        let apMs: [Float] = [4.7, 3.6, 12.7, 9.3]
        diffusers = apMs.map { AllpassDiffuser(maxDelay: Int(Float(sampleRate) * 0.03), delay: $0 / 1000 * Float(sampleRate), gain: 0.7) }
        pre = DelayLine(maxDelaySamples: Int(sampleRate * 0.26) + 8)
        cacheKey = (-1, -1, -1)
    }
    public override func reset() {
        lines.forEach { $0.clear() }; diffusers.forEach { $0.clear() }; pre.clear()
        for i in 0..<8 { state[i] = 0; damp[i].reset() }
    }

    private func updateTopology() {
        let size = p(0), decay = p(1), dampHz = p(3)
        if cacheKey == (size, decay, dampHz) { return }
        cacheKey = (size, decay, dampHz)
        let scale = 0.25 + size * 1.95
        for i in 0..<8 {
            lengths[i] = Self.baseMs[i] / 1000 * fs * scale
            gains[i] = powf(10, -3 * lengths[i] / (max(decay, 0.05) * fs))
            damp[i].setCutoff(dampHz, sampleRate: fs)
        }
    }

    /// Core tank processing for one stereo sample (input already pre-delayed/diffused).
    @inline(__always) final func tank(_ inL: Float, _ inR: Float, modDepth: Float, rate: Float) -> (Float, Float) {
        let m1 = lfo1.next(rate: rate, sampleRate: fs) * modDepth
        let m2 = lfo2.next(rate: rate * 1.37, sampleRate: fs) * modDepth
        var sum: Float = 0
        for i in 0..<8 {
            let mod: Float = i == 1 ? m1 : (i == 6 ? m2 : 0)
            state[i] = damp[i].lowpass(lines[i].read(fractional: lengths[i] + mod)) * gains[i]
            sum += state[i]
        }
        let h = sum * 0.25   // Householder: y = x - (2/N) * sum
        for i in 0..<8 {
            let inject: Float = (i & 1) == 0 ? inL : inR
            lines[i].write(state[i] - h + inject)
        }
        let outL = state[0] - state[2] + state[4] - state[6] + 0.5 * (state[1] - state[5])
        let outR = state[1] - state[3] + state[5] - state[7] + 0.5 * (state[2] - state[6])
        return (outL * 0.5, outR * 0.5)
    }

    /// Shared input conditioning: low cut + pre-delay + diffusion.
    @inline(__always) final func condition(_ l: Float, _ r: Float, predelay: Float, diffusion: Float) -> (Float, Float) {
        pre.write((l + r) * 0.5)
        var x = pre.read(fractional: max(1, predelay))
        x = lowCutL.highpass(x)
        if diffusion > 0.01 {
            for d in diffusers { d.gain = 0.45 + 0.3 * diffusion; x = d.process(x) }
        }
        return (x, lowCutR.highpass(x * 0.5) + x * 0.5)
    }

    /// Hook for subclasses to post-process the wet signal (gating, reversing, shimmer feedback).
    func processWet(_ l: inout Float, _ r: inout Float, input: Float) {}
    /// Hook to add feedback into the tank input.
    func feedbackInput() -> Float { 0 }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !lines.isEmpty else { return }
        updateTopology()
        lowCutL.setCutoff(p(4), sampleRate: fs); lowCutR.setCutoff(p(4), sampleRate: fs)
        let predelay = p(2) / 1000 * fs, diffusion = p(5), modDepth = p(6) * fs * 0.0012
        let width = p(7), wet = p(8), dry = p(9)
        for i in 0..<frameCount {
            let fbIn = feedbackInput()
            let (cl, cr) = condition(left[i] + fbIn, right[i] + fbIn, predelay: predelay, diffusion: diffusion)
            var (wl, wr) = tank(cl * 0.6, cr * 0.6, modDepth: modDepth, rate: 0.5)
            processWet(&wl, &wr, input: (left[i] + right[i]) * 0.5)
            let mid = (wl + wr) * 0.5, side = (wl - wr) * 0.5 * width
            left[i] = left[i] * dry + (mid + side) * wet
            right[i] = right[i] * dry + (mid - side) * wet
        }
    }
}

public final class RoomReverb: FDNReverb {
    public init(kind: Kind = .room) {
        let cfg = Self.config(kind)
        let name = cfg.0, specs = cfg.1
        super.init(kind: kind, name: name, specs: specs)
    }

    static func config(_ kind: Kind) -> (String, [ParameterSpec]) {
        switch kind {
        case .hall: return ("Hall Reverb", baseSpecs(size: 0.8, decay: 2.8, predelay: 25, damping: 7000, diffusion: 0.8, modulation: 0.3, wet: 0.3))
        case .chamber: return ("Chamber Reverb", baseSpecs(size: 0.5, decay: 1.4, predelay: 10, damping: 8000, diffusion: 0.85, modulation: 0.15, wet: 0.3))
        case .plate: return ("Plate Reverb", baseSpecs(size: 0.55, decay: 2.0, predelay: 5, damping: 12000, diffusion: 1, modulation: 0.25, wet: 0.3, lowCut: 150))
        case .cathedral: return ("Cathedral Reverb", baseSpecs(size: 1, decay: 7, predelay: 45, damping: 5000, diffusion: 0.9, modulation: 0.35, wet: 0.35))
        case .ambient: return ("Ambient / Huge Reverb", baseSpecs(size: 1, decay: 15, predelay: 60, damping: 6000, diffusion: 1, modulation: 0.8, wet: 0.4))
        default: return ("Room Reverb", baseSpecs(size: 0.35, decay: 0.8, predelay: 5, damping: 9000, diffusion: 0.7, modulation: 0.1, wet: 0.25))
        }
    }
}

/// 80s gated reverb: a big room whose tail is cut by a gate keyed from the dry input.
public final class GatedReverb: FDNReverb {
    private var env = EnvelopeFollower()
    private var hold = 0
    private var g: Float = 0
    public init() {
        super.init(kind: .gated, name: "Gated Reverb", specs: Self.baseSpecs(size: 0.7, decay: 2.5, predelay: 0, damping: 9000, diffusion: 0.9, modulation: 0.1, wet: 0.5) + [
            ParameterSpec("gateTime", "Gate Time", min: 50, max: 800, default: 280, unit: .milliseconds),
            ParameterSpec("gateThreshold", "Gate Threshold", min: -60, max: 0, default: -30, unit: .decibels),
        ])
    }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        env.set(attackMs: 0.5, releaseMs: 30, sampleRate: fs)
    }
    override func processWet(_ l: inout Float, _ r: inout Float, input: Float) {
        let e = env.process(input)
        if e > dbToGain(p(FDNReverb.baseCount + 1)) { hold = Int(p(FDNReverb.baseCount) / 1000 * fs) }
        let target: Float = hold > 0 ? 1 : 0
        if hold > 0 { hold -= 1 }
        g += (target - g) * (target > g ? 0.05 : 0.004)
        l *= g; r *= g
    }
}

/// Shimmer: octave-up pitch shifting inside the reverb feedback path.
public final class ShimmerReverb: FDNReverb {
    private var shiftL = PitchShiftCore(maxSamples: 16384)
    private var last: Float = 0
    public init() {
        super.init(kind: .shimmer, name: "Shimmer Reverb", specs: Self.baseSpecs(size: 0.9, decay: 8, predelay: 30, damping: 9000, diffusion: 1, modulation: 0.5, wet: 0.4) + [
            ParameterSpec("shimmer", "Shimmer", min: 0, max: 0.9, default: 0.45, unit: .percent),
            ParameterSpec("interval", "Interval", min: -12, max: 24, default: 12, unit: .semitones),
        ])
    }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        shiftL = PitchShiftCore(maxSamples: Int(sampleRate * 0.2))
    }
    override func feedbackInput() -> Float { last * p(FDNReverb.baseCount) }
    override func processWet(_ l: inout Float, _ r: inout Float, input: Float) {
        last = fastTanh(shiftL.process((l + r) * 0.5, ratio: semitonesToRatio(p(FDNReverb.baseCount + 1)), window: fs * 0.06))
    }
}

/// Reverse reverb: the reverb tail is captured in segments and played backwards (swell effect).
public final class ReverseReverb: FDNReverb {
    private var bufA: [Float] = [], bufB: [Float] = []
    private var bufAR: [Float] = [], bufBR: [Float] = []
    private var pos = 0
    private var segLen = 1
    public init() {
        super.init(kind: .reverse, name: "Reverse Reverb", specs: Self.baseSpecs(size: 0.8, decay: 3, predelay: 0, damping: 8000, diffusion: 0.9, modulation: 0.2, wet: 0.5) + [
            ParameterSpec("length", "Segment Length", min: 100, max: 2000, default: 600, unit: .milliseconds),
        ])
    }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        let n = Int(sampleRate * 2.05)
        bufA = [Float](repeating: 0, count: n); bufB = bufA; bufAR = bufA; bufBR = bufA
        pos = 0
    }
    override func processWet(_ l: inout Float, _ r: inout Float, input: Float) {
        guard !bufA.isEmpty else { return }
        if pos == 0 { segLen = max(64, min(bufA.count, Int(p(FDNReverb.baseCount) / 1000 * fs))) }
        bufA[pos] = l; bufAR[pos] = r
        let rp = segLen - 1 - pos
        let t = Float(pos) / Float(segLen)
        let envl = t * t * (1 - t * t * t * t) * 1.6   // swell, fast cut at boundary
        l = bufB[rp] * envl; r = bufBR[rp] * envl
        pos += 1
        if pos >= segLen { pos = 0; swap(&bufA, &bufB); swap(&bufAR, &bufBR) }
    }
}

/// Spring reverb: dispersive allpass chain inside a feedback loop ("boing" + drip).
public final class SpringReverb: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("decay", "Decay", min: 0.2, max: 6, default: 2, unit: .seconds),
        ParameterSpec("tension", "Tension", min: 0, max: 1, default: 0.5, unit: .percent),
        ParameterSpec("tone", "Tone", min: 1000, max: 8000, default: 3500, unit: .hertz, log: true),
        ParameterSpec("drip", "Drip", min: 0, max: 1, default: 0.5, unit: .percent),
        ParameterSpec("wet", "Wet", min: 0, max: 1, default: 0.35, unit: .percent),
    ]
    private var apL = [FirstOrderAllpass](repeating: FirstOrderAllpass(), count: 16)
    private var apR = [FirstOrderAllpass](repeating: FirstOrderAllpass(), count: 16)
    private var loopL = DelayLine(maxDelaySamples: 8192), loopR = DelayLine(maxDelaySamples: 8192)
    private var lpL = OnePole(), lpR = OnePole(), hpL = OnePole(), hpR = OnePole()
    private var lfo = LFO()
    public init() { super.init(typeID: "reverb.spring", name: "Spring Reverb", specs: Self.specs) }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        loopL = DelayLine(maxDelaySamples: Int(sampleRate * 0.1)); loopR = DelayLine(maxDelaySamples: Int(sampleRate * 0.1))
        hpL.setCutoff(150, sampleRate: fs); hpR.setCutoff(150, sampleRate: fs)
    }
    public override func reset() { loopL.clear(); loopR.clear(); for i in 0..<16 { apL[i].reset(); apR[i].reset() } }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let lenL = (0.033 + p(1) * 0.012) * fs, lenR = lenL * 1.13
        let g = powf(10, -3 * lenL / (p(0) * fs))
        let a = 0.55 + 0.25 * p(3)
        lpL.setCutoff(p(2), sampleRate: fs); lpR.setCutoff(p(2), sampleRate: fs)
        let wet = p(4)
        for i in 0..<frameCount {
            let x = (left[i] + right[i]) * 0.5
            let wob = 1 + 0.002 * lfo.next(rate: 3.3, sampleRate: fs)
            var yl = loopL.read(fractional: lenL * wob), yr = loopR.read(fractional: lenR * wob)
            for s in 0..<16 { yl = apL[s].process(yl, a: a); yr = apR[s].process(yr, a: a) }
            yl = lpL.lowpass(hpL.highpass(yl)); yr = lpR.lowpass(hpR.highpass(yr))
            loopL.write(x + fastTanh(yl * g)); loopR.write(x + fastTanh(yr * g))
            left[i] += yl * wet; right[i] += yr * wet
        }
    }
}

/// Convolution reverb: loads user IRs (extras["irPath"]) or synthesizes a stereo IR.
public final class ConvolutionReverb: EffectBase {
    public static let irTypes = ["Synthetic Hall", "Synthetic Room", "Dark Cave", "Bright Plate", "Custom IR File"]
    public static let specs: [ParameterSpec] = [
        .choice("irType", "Impulse", irTypes),
        ParameterSpec("decay", "Synth Decay", min: 0.2, max: 12, default: 2.5, unit: .seconds, log: true),
        ParameterSpec("predelay", "Pre-delay", min: 0, max: 200, default: 10, unit: .milliseconds),
        ParameterSpec("wet", "Wet", min: 0, max: 1, default: 0.3, unit: .percent),
        ParameterSpec("dry", "Dry", min: 0, max: 1, default: 1, unit: .percent),
    ]
    private let swap = RTObjectSwap<ConvolverPair>()
    private var pre = DelayLine(maxDelaySamples: 16384), preR = DelayLine(maxDelaySamples: 16384)
    private var wl: ScratchBuffer = ScratchBuffer(capacity: 4096), wr: ScratchBuffer = ScratchBuffer(capacity: 4096)
    private var builtFor: (Int, Float) = (-1, -1)

    public init() { super.init(typeID: "reverb.convolution", name: "Convolution Reverb", specs: Self.specs) }

    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        wl = ScratchBuffer(capacity: maxFrames); wr = ScratchBuffer(capacity: maxFrames)
        pre = DelayLine(maxDelaySamples: Int(sampleRate * 0.21)); preR = DelayLine(maxDelaySamples: Int(sampleRate * 0.21))
        rebuild()
    }
    public override func extraDidChange(_ key: String) { if key == "irPath" { builtFor = (-1, -1); rebuild() } }
    public override func parametersChangedOffline() { if builtFor != (pi(0), p(1)) { rebuild() } }

    public static func synthesizeIR(type: Int, decay: Float, sampleRate: Float, seed: UInt64) -> [Float] {
        let n = Int(min(decay * 1.3, 14) * sampleRate)
        var rng = SplitMix64(seed: seed)
        var ir = [Float](repeating: 0, count: n)
        let (lpHz, density): (Float, Float) = [(6500, 1), (8000, 1), (2500, 0.7), (12000, 1)][min(max(type, 0), 3)]
        var lp = OnePole(); lp.setCutoff(lpHz, sampleRate: sampleRate)
        var lp2 = OnePole()
        for i in 0..<n {
            let t = Float(i) / sampleRate
            let envl = expf(-6.9 * t / decay)                     // -60 dB at `decay`
            let onset = min(1, t / 0.004)
            var x = Float(rng.unit() * 2 - 1)
            if Float(rng.unit()) > density { x = 0 }
            // Darken over time: cutoff falls as the tail decays.
            lp2.setCutoff(lpHz * (0.3 + 0.7 * envl), sampleRate: sampleRate)
            ir[i] = lp2.lowpass(lp.lowpass(x)) * envl * onset
        }
        let e = sqrtf(ir.reduce(0) { $0 + $1 * $1 })
        if e > 0 { for i in 0..<n { ir[i] /= e } }
        return ir
    }

    private func rebuild() {
        builtFor = (pi(0), p(1))
        let block = 512
        if pi(0) == Self.irTypes.count - 1, let path = extras["irPath"],
           let (l, r) = CabinetIRFactory.load(path: path, sampleRate: sampleRate) {
            swap.publish(ConvolverPair(left: l, right: r, blockSize: block))
        } else {
            let t = min(pi(0), 3)
            let l = Self.synthesizeIR(type: t, decay: p(1), sampleRate: fs, seed: 11)
            let r = Self.synthesizeIR(type: t, decay: p(1), sampleRate: fs, seed: 29)
            swap.publish(ConvolverPair(left: l, right: r, blockSize: block))
        }
    }
    public override func reset() { swap.latest?.left.reset(); swap.latest?.right.reset(); pre.clear(); preR.clear() }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard let pair = swap.acquire() else { return }
        let n = min(frameCount, wl.capacity)
        let d = max(1, p(2) / 1000 * fs)
        for i in 0..<n {
            pre.write(left[i]); preR.write(right[i])
            wl.data[i] = pre.read(fractional: d); wr.data[i] = preR.read(fractional: d)
        }
        pair.left.process(input: wl.data, output: wl.data, count: n)
        pair.right.process(input: wr.data, output: wr.data, count: n)
        let wet = p(3), dry = p(4)
        for i in 0..<n {
            left[i] = left[i] * dry + wl.data[i] * wet
            right[i] = right[i] * dry + wr.data[i] * wet
        }
    }
}
