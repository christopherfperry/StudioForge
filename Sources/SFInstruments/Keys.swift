import Foundation
import SFCore
import SFEffects

/// Multi-model keyboard instrument: acoustic piano (additive, inharmonic partials), electric piano
/// (reedy FM with "bark"), Rhodes-style tine (FM bell), drawbar organ with rotary, harpsichord
/// (Karplus–Strong) and string machine (detuned saw ensemble + chorus).
public final class KeysInstrument: PolyInstrument {
    public static let models = ["Piano", "Electric Piano", "Rhodes", "Organ", "Harpsichord", "String Machine"]
    public static let registrations = ["888000000 (Full)", "800000888 (Jazz)", "868000000 (Gospel)", "008800000 (Flute)", "888888888 (Wall)", "806000000 (Goth Chapel)"]
    public static let specs: [ParameterSpec] = [
        .choice("model", "Model", models),                                                        // 0
        ParameterSpec("brightness", "Brightness", min: 0, max: 1, default: 0.5, unit: .percent),  // 1
        ParameterSpec("decay", "Decay", min: 0.2, max: 3, default: 1),                            // 2
        ParameterSpec("release", "Release", min: 0.02, max: 4, default: 0.35, unit: .seconds, log: true), // 3
        ParameterSpec("attackNoise", "Hammer / Click", min: 0, max: 1, default: 0.3, unit: .percent),     // 4
        ParameterSpec("modRate", "Tremolo / Rotary Rate", min: 0.1, max: 8, default: 5.5, log: true),     // 5
        ParameterSpec("modDepth", "Tremolo / Rotary Depth", min: 0, max: 1, default: 0.3, unit: .percent),// 6
        .choice("registration", "Organ Drawbars", registrations),                                  // 7
        ParameterSpec("velocity", "Velocity Sens.", min: 0, max: 1, default: 0.8, unit: .percent), // 8
        ParameterSpec("width", "Stereo Width", min: 0, max: 1, default: 0.6, unit: .percent),      // 9
        ParameterSpec("gain", "Volume", min: -36, max: 12, default: -6, unit: .decibels),          // 10
        ParameterSpec("tune", "Tune", min: -50, max: 50, default: 0, unit: .cents),                // 11
        ParameterSpec("ensemble", "Ensemble / Chorus", min: 0, max: 1, default: 0.5, unit: .percent), // 12
        ParameterSpec("attack", "Attack (Strings/Organ)", min: 0.001, max: 3, default: 0.4, unit: .seconds, log: true), // 13
    ]
    static let drawbarRatios: [Float] = [0.5, 1.5, 1, 2, 3, 4, 5, 6, 8]
    /// Pre-parsed drawbar levels (0-8) for each registration (avoids string parsing on the audio thread).
    static let drawbarLevels: [[Float]] = registrations.map { reg in reg.prefix(9).compactMap { Float(String($0)) } }

    private let chorus = Chorus()
    private var rotorDelayL = DelayLine(maxDelaySamples: 2048), rotorDelayR = DelayLine(maxDelaySamples: 2048)
    private var rotorLFO = LFO()
    private var tremLFO = LFO()

    public init() { super.init(typeID: "keys", name: "Keys", specs: Self.specs) }

    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        chorus.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        rotorDelayL = DelayLine(maxDelaySamples: Int(sampleRate * 0.01)); rotorDelayR = DelayLine(maxDelaySamples: Int(sampleRate * 0.01))
    }
    public override func makeVoice() -> SynthVoice { Voice(keys: self) }
    public override var voiceCount: Int { 20 }

    public override func postProcess(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let model = pi(0), depth = p(6), rate = p(5)
        switch model {
        case 3: // Organ rotary (Doppler + amplitude panning)
            for i in 0..<frameCount {
                let m = rotorLFO.next(rate: rate, sampleRate: fs)
                let x = (left[i] + right[i]) * 0.5
                rotorDelayL.write(x); rotorDelayR.write(x)
                let dl = rotorDelayL.read(cubic: fs * (0.002 + 0.0012 * depth * (1 + m)))
                let dr = rotorDelayR.read(cubic: fs * (0.002 + 0.0012 * depth * (1 - m)))
                left[i] = dl * (1 - 0.4 * depth * m); right[i] = dr * (1 + 0.4 * depth * m)
            }
        case 1, 2: // EP / Rhodes stereo tremolo
            if depth > 0.001 {
                for i in 0..<frameCount {
                    let m = tremLFO.next(rate: rate, sampleRate: fs) * depth * p(9)
                    left[i] *= 1 - m * 0.5; right[i] *= 1 + m * 0.5
                }
            }
            if p(12) > 0.01 { chorus.parameters["wet"]?.value = p(12) * 0.5; chorus.process(left: left, right: right, frameCount: frameCount) }
        case 5:
            chorus.parameters["wet"]?.value = p(12)
            chorus.parameters["voices"]?.value = 3
            chorus.parameters["depth"]?.value = 6
            chorus.process(left: left, right: right, frameCount: frameCount)
        default: break
        }
    }

    final class Voice: SynthVoice {
        unowned let keys: KeysInstrument
        static let maxPartials = 20
        // Additive partial bank (complex rotators)
        var re = [Float](repeating: 0, count: maxPartials), im = [Float](repeating: 0, count: maxPartials)
        var cw = [Float](repeating: 1, count: maxPartials), sw = [Float](repeating: 0, count: maxPartials)
        var amps = [Float](repeating: 0, count: maxPartials), decays = [Float](repeating: 1, count: maxPartials)
        var pans = [Float](repeating: 0.5, count: maxPartials)
        var partialCount = 0
        // FM / oscillators
        var phC: Float = 0, phM: Float = 0, phB: Float = 0
        var modIndex: Float = 0, modDecay: Float = 0.999, bellAmp: Float = 0, bellDecay: Float = 0.999
        var saws = [Oscillator(phase: 0.1), Oscillator(phase: 0.5), Oscillator(phase: 0.8)]
        var filt = SVFilter()
        // Karplus–Strong
        var ks = [Float](repeating: 0, count: 4096), ks2 = [Float](repeating: 0, count: 4096)
        var ksLen: Float = 100, ksPos = 0, ksLast: Float = 0, ksLast2: Float = 0
        var env = ADSR()
        var noiseEnv: Float = 0
        var rng = FastRandom(seed: 777)
        var model = 0
        var freq: Float = 440

        init(keys: KeysInstrument) { self.keys = keys }
        override var isActive: Bool { env.isActive }

        override func start(note: Int, velocity v: Float, legato: Bool) {
            super.start(note: note, velocity: v, legato: legato)
            let k = keys, fs = k.fs
            model = k.pi(0)
            let vel = 1 - k.p(8) + k.p(8) * v
            freq = midiToHz(Float(note) + k.p(11) / 100)
            let bright = k.p(1), decayMul = k.p(2)
            let keyScale = powf(2, -(Float(note) - 60) / 24)  // higher notes decay faster
            partialCount = 0
            noiseEnv = k.p(4) * vel
            func addPartial(_ f: Float, _ a: Float, _ decaySeconds: Float, _ pan: Float) {
                guard partialCount < Voice.maxPartials, f < fs * 0.45 else { return }
                let w = twoPi * f / fs
                let i = partialCount
                re[i] = 1; im[i] = 0; cw[i] = cosf(w); sw[i] = sinf(w)
                amps[i] = a; decays[i] = decaySeconds > 50 ? 1 : onePoleCoef(seconds: decaySeconds, sampleRate: fs)
                pans[i] = pan
                partialCount += 1
            }
            switch model {
            case 0: // Piano: inharmonic partials, two detuned strings
                let B: Float = 0.0004 * powf(2, (Float(note) - 60) / 18)
                let rolloff = 1.6 - bright * 0.9 - v * 0.4
                for n in 1...10 {
                    let fn = Float(n) * freq * sqrtf(1 + B * Float(n * n))
                    let a = vel / powf(Float(n), rolloff) * 0.35
                    let d = 4.5 * decayMul * keyScale / (1 + Float(n) * 0.35)
                    addPartial(fn, a, d, 0.5 - 0.15 * k.p(9))
                    addPartial(fn * 1.0007, a * 0.8, d * 1.3, 0.5 + 0.15 * k.p(9))
                }
                env.set(attack: 0.001, decay: 30, sustain: 1, release: k.p(3) * 0.6, sampleRate: fs)
            case 3: // Organ drawbars
                let digits = KeysInstrument.drawbarLevels[min(max(k.pi(7), 0), KeysInstrument.drawbarLevels.count - 1)]
                for i in 0..<digits.count where digits[i] > 0 {
                    let d = digits[i]
                    addPartial(freq * KeysInstrument.drawbarRatios[i], d / 8 * 0.18, 100, 0.5)
                }
                env.set(attack: max(0.004, k.p(13) * 0.02), decay: 1, sustain: 1, release: 0.03 + k.p(3) * 0.05, sampleRate: fs)
                noiseEnv = k.p(4) * 0.5
            case 1, 2: // EP / Rhodes FM
                phC = 0; phM = 0; phB = 0
                modIndex = (model == 1 ? 1.6 : 1.1) * (0.4 + vel * (0.8 + bright))
                modDecay = onePoleCoef(seconds: model == 1 ? 0.6 : 0.35, sampleRate: fs)
                bellAmp = model == 2 ? 0.25 * vel * (0.5 + bright) : 0.05
                bellDecay = onePoleCoef(seconds: 0.12, sampleRate: fs)
                env.set(attack: 0.001, decay: 3.5 * decayMul * keyScale, sustain: 0, release: k.p(3) * 0.5, sampleRate: fs)
            case 4: // Harpsichord
                ksLen = min(4000, fs / freq)
                for i in 0..<Int(ksLen) + 2 {
                    // Bright plucked excitation, slightly lowpassed by brightness.
                    let x = rng.bipolar()
                    ks[i] = x * vel; ks2[i] = rng.bipolar() * vel * 0.6
                }
                if bright < 0.5 { for i in 1..<Int(ksLen) { ks[i] = ks[i] * 0.5 + ks[i - 1] * 0.5 } }
                ksPos = 0; ksLast = 0; ksLast2 = 0
                env.set(attack: 0.001, decay: 10, sustain: 1, release: 0.08, sampleRate: fs)
            default: // String machine
                env.set(attack: k.p(13), decay: 1, sustain: 1, release: max(0.3, k.p(3) * 2), sampleRate: fs)
            }
            env.gate(true)
        }
        override func release() { super.release(); env.gate(false) }
        override func kill() { super.kill(); env.kill() }

        override func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
            let k = keys, fs = k.fs
            let g = dbToGain(k.p(10))
            switch model {
            case 0, 3:
                for i in 0..<frameCount {
                    let e = env.next()
                    var l: Float = 0, r: Float = 0
                    for p in 0..<partialCount {
                        let nr = re[p] * cw[p] - im[p] * sw[p]
                        im[p] = re[p] * sw[p] + im[p] * cw[p]
                        re[p] = nr
                        amps[p] *= decays[p]
                        let s = im[p] * amps[p]
                        l += s * (1 - pans[p]); r += s * pans[p]
                    }
                    var noise: Float = 0
                    if noiseEnv > 1e-4 { noise = rng.bipolar() * noiseEnv * 0.15; noiseEnv *= model == 3 ? 0.993 : 0.996 }
                    left[i] += (l * 2 + noise) * e * g; right[i] += (r * 2 + noise) * e * g
                }
                // Renormalise rotators once per block to prevent numerical drift.
                for p in 0..<partialCount {
                    let m = sqrtf(re[p] * re[p] + im[p] * im[p])
                    if m > 0 { re[p] /= m; im[p] /= m }
                }
            case 1, 2:
                let ratioB: Float = 14.0
                let w = freq / fs
                let bark: Float = model == 1 ? 1.5 + velocity * 2 : 1
                for i in 0..<frameCount {
                    let e = env.next()
                    let mSig = sinf(twoPi * phM) * modIndex
                    var c = sinf(twoPi * phC + mSig)
                    let bell = sinf(twoPi * phB) * bellAmp
                    if model == 1 { c = fastTanh(c * bark) / fastTanh(bark) }
                    phC += w; phM += w; phB += w * ratioB
                    if phC >= 1 { phC -= 1 }; if phM >= 1 { phM -= 1 }; if phB >= 1 { phB -= floorf(phB) }
                    modIndex *= modDecay; bellAmp *= bellDecay
                    let s = (c + bell) * e * g * 0.3 * (0.5 + 0.5 * velocity)
                    left[i] += s; right[i] += s
                }
            case 4:
                let n = Int(ksLen)
                let frac = ksLen - Float(n)
                for i in 0..<frameCount {
                    let e = env.next()
                    let idx = ksPos % n
                    let next = (idx + 1) % n
                    let y = ks[idx] * (1 - frac) + ks[next] * frac
                    let filtered = 0.5 * (y + ksLast) * 0.998
                    ksLast = y
                    ks[idx] = filtered
                    let y2 = ks2[idx % max(1, n / 2)]
                    let f2 = 0.5 * (y2 + ksLast2) * 0.997
                    ksLast2 = y2
                    ks2[idx % max(1, n / 2)] = f2
                    ksPos += 1
                    let s = (y + y2 * 0.5) * e * g * 0.5
                    left[i] += s * 0.9; right[i] += s
                }
            default:
                let fc = 1500 + k.p(1) * 6000
                filt.set(cutoff: fc, resonance: 0.6, sampleRate: fs)
                let dt0 = freq / fs, dt1 = freq * 1.004 / fs, dt2 = freq * 0.996 / fs
                for i in 0..<frameCount {
                    let e = env.next()
                    let x = saws[0].next(.saw, dt: dt0) + saws[1].next(.saw, dt: dt1) + saws[2].next(.saw, dt: dt2)
                    let s = filt.lowpass(x) * e * g * 0.2 * (0.6 + 0.4 * velocity)
                    left[i] += s; right[i] += s
                }
            }
            if !env.isActive { note = -1 }
        }
    }
}
