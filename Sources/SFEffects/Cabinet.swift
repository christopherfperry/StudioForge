import Foundation
import SFCore

/// Synthesizes speaker-cabinet impulse responses from filter models (original, not sampled from
/// any commercial product) and loads user IRs (WAV/AIFF, or anything the platform decoder handles).
public enum CabinetIRFactory {
    public static let models = ["1x12 Open Back", "2x12 Vintage", "4x12 Closed (V-type)", "4x12 Greenback", "4x10 Bass",
                                "8x10 Bass", "1x8 Lo-Fi", "Megaphone", "Custom IR"]

    /// Builds an IR of `length` samples for a model; `mic` 0 = cone centre (bright) ... 1 = edge (dark).
    public static func synthesize(model: Int, mic: Float, sampleRate: Float, length: Int = 1024) -> [Float] {
        // (resonance Hz, resonance gain, presence Hz, presence dB, top cut Hz, lp stages, notch Hz, reflection ms)
        let table: [(Float, Float, Float, Float, Float, Int, Float, Float)] = [
            (95, 4, 2400, 3, 6500, 2, 1500, 0.9),
            (90, 5, 2200, 4, 5500, 3, 1200, 1.1),
            (85, 6, 2600, 5, 5000, 3, 1000, 1.4),
            (100, 5, 1900, 4, 4500, 3, 1300, 1.3),
            (60, 6, 1800, 2, 5000, 2, 900, 1.0),
            (50, 8, 1500, 2, 3800, 3, 700, 1.6),
            (180, 3, 2000, 6, 3500, 3, 1100, 0.5),
            (500, 2, 1800, 10, 3200, 4, 2600, 0.3),
        ]
        let t = table[min(max(model, 0), table.count - 1)]
        var ir = [Float](repeating: 0, count: length)
        ir[0] = 1
        // Short cabinet reflection (comb) for the boxy character
        let refl = Int(t.7 / 1000 * sampleRate)
        if refl > 0 && refl < length { ir[refl] += 0.35 }
        if 2 * refl < length { ir[2 * refl] -= 0.12 }
        var filters: [Biquad] = [
            Biquad(.make(.highpass, freq: t.0 * 0.7, q: 0.9, sampleRate: sampleRate)),
            Biquad(.make(.peak, freq: t.0, q: 1.6, gainDB: t.1, sampleRate: sampleRate)),
            Biquad(.make(.peak, freq: t.2, q: 1.2, gainDB: t.3 - mic * 4, sampleRate: sampleRate)),
            Biquad(.make(.notch, freq: t.6, q: 2.5, sampleRate: sampleRate)),
        ]
        let cut = t.4 * (1 - 0.45 * mic)
        for _ in 0..<t.5 { filters.append(Biquad(.make(.lowpass, freq: cut, q: 0.8, sampleRate: sampleRate))) }
        for i in 0..<length {
            var x = ir[i]
            for k in 0..<filters.count { x = filters[k].process(x) }
            ir[i] = x
        }
        // Fade the tail and normalise to unity energy-ish gain.
        for i in 0..<length { ir[i] *= 0.5 + 0.5 * cosf(Float.pi * Float(i) / Float(length)) }
        let energy = sqrtf(ir.reduce(0) { $0 + $1 * $1 })
        if energy > 0 { for i in 0..<length { ir[i] /= energy * 1.2 } }
        return ir
    }

    /// Loads a user IR, resampled to the session rate. Returns (left, right).
    public static func load(path: String, sampleRate: Double, maxSeconds: Double = 12) -> ([Float], [Float])? {
        guard let a = try? AudioDecoding.decode(URL(fileURLWithPath: path)), a.frameCount > 0 else { return nil }
        let r = Resampler.resample(a, to: sampleRate)
        let maxN = Int(maxSeconds * sampleRate)
        let l = Array(r.channels[0].prefix(maxN))
        let rr = Array((r.channels.count > 1 ? r.channels[1] : r.channels[0]).prefix(maxN))
        return (l, rr)
    }
}

/// Holds a pair of convolvers so they can be swapped atomically when the IR changes.
final class ConvolverPair {
    let left: Convolver
    let right: Convolver
    init(left: [Float], right: [Float], blockSize: Int) {
        self.left = Convolver(ir: left, blockSize: blockSize)
        self.right = Convolver(ir: right, blockSize: blockSize)
    }
}

/// Speaker cabinet simulation by zero-latency convolution with synthesized or user IRs.
public final class CabinetSim: EffectBase {
    public static let specs: [ParameterSpec] = [
        .choice("model", "Cabinet", CabinetIRFactory.models, default: 2),
        ParameterSpec("mic", "Mic Position", min: 0, max: 1, default: 0.3, unit: .percent),
        ParameterSpec("lowCut", "Low Cut", min: 20, max: 300, default: 60, unit: .hertz, log: true),
        ParameterSpec("highCut", "High Cut", min: 2000, max: 20000, default: 12000, unit: .hertz, log: true),
        ParameterSpec("output", "Output", min: -24, max: 24, default: 0, unit: .decibels),
    ]
    private let swap = RTObjectSwap<ConvolverPair>()
    private var hpL = Biquad(), hpR = Biquad(), lpL = Biquad(), lpR = Biquad()
    private var lastModel = -1, lastMic: Float = -1, lastLC: Float = -1, lastHC: Float = -1

    public init() { super.init(typeID: "cabinet", name: "Cabinet (IR)", specs: Self.specs) }

    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        rebuildIR()
    }
    public override func extraDidChange(_ key: String) { if key == "irPath" { rebuildIR() } }

    /// Non-real-time: (re)build the IR. Also called from the main thread when model/mic changes.
    public func rebuildIR() {
        lastModel = pi(0); lastMic = p(1)
        if lastModel == CabinetIRFactory.models.count - 1, let path = extras["irPath"],
           let (l, r) = CabinetIRFactory.load(path: path, sampleRate: sampleRate, maxSeconds: 0.5) {
            swap.publish(ConvolverPair(left: l, right: r, blockSize: 128))
        } else {
            let ir = CabinetIRFactory.synthesize(model: min(lastModel, CabinetIRFactory.models.count - 2), mic: lastMic, sampleRate: fs)
            swap.publish(ConvolverPair(left: ir, right: ir, blockSize: 128))
        }
    }

    /// Call from the UI after changing model/mic (IR synthesis must not run on the audio thread).
    public override func parametersChangedOffline() {
        if pi(0) != lastModel || p(1) != lastMic { rebuildIR() }
    }

    public override func reset() { swap.latest?.left.reset(); swap.latest?.right.reset() }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        if p(2) != lastLC { lastLC = p(2); let c = BiquadCoefficients.make(.highpass, freq: lastLC, q: 0.707, sampleRate: fs); hpL.c = c; hpR.c = c }
        if p(3) != lastHC { lastHC = p(3); let c = BiquadCoefficients.make(.lowpass, freq: lastHC, q: 0.707, sampleRate: fs); lpL.c = c; lpR.c = c }
        guard let pair = swap.acquire() else { return }
        pair.left.process(input: left, output: left, count: frameCount)
        pair.right.process(input: right, output: right, count: frameCount)
        let g = dbToGain(p(4))
        for i in 0..<frameCount {
            left[i] = lpL.process(hpL.process(left[i])) * g
            right[i] = lpR.process(hpR.process(right[i])) * g
        }
    }
}
