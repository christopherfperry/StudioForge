import Foundation
import SFCore

/// General-MIDI-mapped drum pads.
public enum DrumPad: Int, CaseIterable, Codable {
    case kick = 36, rim = 37, snare = 38, clap = 39, tomLow = 41, hatClosed = 42, hatPedal = 44, tomMid = 45
    case hatOpen = 46, tomHigh = 48, crash = 49, ride = 51, china = 52, tambourine = 54, cowbell = 56, metal = 75

    public var name: String {
        switch self {
        case .kick: return "Kick"; case .rim: return "Rim"; case .snare: return "Snare"; case .clap: return "Clap"
        case .tomLow: return "Low Tom"; case .hatClosed: return "Closed Hat"; case .hatPedal: return "Pedal Hat"
        case .tomMid: return "Mid Tom"; case .hatOpen: return "Open Hat"; case .tomHigh: return "High Tom"
        case .crash: return "Crash"; case .ride: return "Ride"; case .china: return "China"
        case .tambourine: return "Tambourine"; case .cowbell: return "Cowbell"; case .metal: return "Metal Hit"
        }
    }
    /// Key used in beat-style JSON lanes.
    public var laneKey: String {
        switch self {
        case .kick: return "kick"; case .rim: return "rim"; case .snare: return "snare"; case .clap: return "clap"
        case .tomLow: return "tomLow"; case .hatClosed: return "hatClosed"; case .hatPedal: return "hatPedal"
        case .tomMid: return "tomMid"; case .hatOpen: return "hatOpen"; case .tomHigh: return "tomHigh"
        case .crash: return "crash"; case .ride: return "ride"; case .china: return "china"
        case .tambourine: return "tambourine"; case .cowbell: return "cowbell"; case .metal: return "metal"
        }
    }
    public static func fromLaneKey(_ k: String) -> DrumPad? { allCases.first { $0.laneKey == k } }
    /// Default synthesis model for this pad.
    var defaultModel: Int {
        switch self {
        case .kick: return 0; case .snare: return 1; case .rim: return 6; case .clap: return 5
        case .tomLow, .tomMid, .tomHigh: return 2
        case .hatClosed, .hatPedal, .hatOpen: return 3
        case .crash, .ride, .china: return 4
        case .tambourine: return 7; case .cowbell: return 8; case .metal: return 9
        }
    }
    var defaultTune: Float {
        switch self { case .tomLow: return -5; case .tomHigh: return 5; case .hatPedal: return -2; case .ride: return -4; case .china: return 3; default: return 0 }
    }
    var defaultDecay: Float {
        switch self { case .hatOpen: return 2.5; case .hatPedal: return 0.6; case .crash: return 2.5; case .ride: return 3; case .china: return 2; default: return 1 }
    }
}

/// Drum machine / sampler. Each of the 16 pads is either synthesized (kick, snare, tom, hat,
/// cymbal, clap, rim, tambourine, cowbell, industrial metal) or plays a loaded sample
/// (extras["pad<note>.sample"] = file path). Pad parameters are exposed as "pad<note>.<param>".
public final class DrumMachine: Instrument {
    public static let models = ["Kick", "Snare", "Tom", "Hi-Hat", "Cymbal", "Clap", "Rim", "Tambourine", "Cowbell", "Metal", "Sample"]
    static let padParams = ["model", "tune", "decay", "tone", "snap", "drive", "level", "pan"]

    public let typeID = "drums"
    public let displayName = "Drum Machine"
    public let parameters: ParameterSet
    public private(set) var extras: [String: String] = [:]
    private var sampleRate: Float = 48_000
    private var pads: [Int: PadVoice] = [:]
    private var padList: [PadVoice] = []
    private let master: Int

    public static func makeSpecs() -> [ParameterSpec] {
        var specs: [ParameterSpec] = [ParameterSpec("master", "Kit Volume", min: -36, max: 12, default: -3, unit: .decibels)]
        for pad in DrumPad.allCases {
            let pfx = "pad\(pad.rawValue)."
            specs += [
                .choice(pfx + "model", "\(pad.name) Model", models, default: pad.defaultModel),
                ParameterSpec(pfx + "tune", "\(pad.name) Tune", min: -24, max: 24, default: pad.defaultTune, unit: .semitones),
                ParameterSpec(pfx + "decay", "\(pad.name) Decay", min: 0.1, max: 4, default: pad.defaultDecay),
                ParameterSpec(pfx + "tone", "\(pad.name) Tone", min: 0, max: 1, default: 0.5, unit: .percent),
                ParameterSpec(pfx + "snap", "\(pad.name) Snap/Noise", min: 0, max: 1, default: 0.5, unit: .percent),
                ParameterSpec(pfx + "drive", "\(pad.name) Drive", min: 0, max: 1, default: 0, unit: .percent),
                ParameterSpec(pfx + "level", "\(pad.name) Level", min: -48, max: 12, default: pad == .kick || pad == .snare ? 0 : -4, unit: .decibels),
                ParameterSpec(pfx + "pan", "\(pad.name) Pan", min: -1, max: 1, default: 0),
            ]
        }
        return specs
    }

    public init() {
        parameters = ParameterSet(Self.makeSpecs())
        master = 0
    }

    public func prepare(sampleRate: Double, maxFrames: Int) {
        self.sampleRate = Float(sampleRate)
        var dict: [Int: PadVoice] = [:]
        var list: [PadVoice] = []
        for (i, pad) in DrumPad.allCases.enumerated() {
            let v = PadVoice(pad: pad, paramBase: 1 + i * Self.padParams.count, owner: self)
            if let path = extras["pad\(pad.rawValue).sample"] { v.loadSample(path: path, sampleRate: sampleRate) }
            dict[pad.rawValue] = v; list.append(v)
        }
        pads = dict; padList = list
    }

    public func setExtra(_ key: String, value: String) {
        extras[key] = value
        if key.hasSuffix(".sample"), let note = Int(key.dropFirst(3).prefix { $0.isNumber }), let v = pads[note] {
            v.loadSample(path: value, sampleRate: Double(sampleRate))
        }
    }

    public func noteOn(note: Int, velocity: Float) {
        guard let v = pads[note] ?? pads[Self.fallbackPad(note)] else { return }
        if v.pad == .hatClosed || v.pad == .hatPedal { pads[DrumPad.hatOpen.rawValue]?.choke() }
        v.trigger(velocity: velocity)
    }
    /// Maps other GM drum notes onto the nearest pad.
    static func fallbackPad(_ n: Int) -> Int {
        switch n {
        case 35: return 36; case 40: return 38; case 43: return 41; case 47: return 45; case 50: return 48
        case 53, 59: return 51; case 55, 57: return 49; case 58...74: return 75; default: return 75
        }
    }
    public func noteOff(note: Int) {}
    public func allNotesOff(hard: Bool) { if hard { padList.forEach { $0.choke() } } }
    public func pitchBend(semitones: Float) {}
    public func controlChange(_ cc: Int, value: Float) {}

    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        left.update(repeating: 0, count: frameCount)
        right.update(repeating: 0, count: frameCount)
        let g = dbToGain(parameters[master])
        for v in padList where v.active { v.render(left: left, right: right, frameCount: frameCount, gain: g) }
    }

    @inline(__always) func param(_ i: Int) -> Float { parameters.all[i].value }
    var fs: Float { sampleRate }
}

final class PadVoice {
    let pad: DrumPad
    let base: Int
    unowned let owner: DrumMachine
    var active = false
    var t: Float = 0
    var vel: Float = 1
    var ph = [Float](repeating: 0, count: 6)
    var rng = FastRandom(seed: 0xDEAD_BEEF)
    var bp = SVFilter(), hp = SVFilter(), lp = SVFilter()
    var sample: [Float] = []
    var samplePos: Double = 0
    var level: Float = 1
    var choking = false
    static let metallicRatios: [Float] = [1, 1.4823, 1.8004, 2.5462, 2.6301, 3.8968] // 808-style square cluster
    static let metalRatios: [Float] = [1, 2.76, 5.40, 8.93, 1.51, 3.17]

    init(pad: DrumPad, paramBase: Int, owner: DrumMachine) { self.pad = pad; self.base = paramBase; self.owner = owner }

    func loadSample(path: String, sampleRate: Double) {
        guard !path.isEmpty, let a = try? AudioDecoding.decode(URL(fileURLWithPath: path)) else { sample = []; return }
        sample = Resampler.resample(a, to: sampleRate).mono
    }

    func trigger(velocity: Float) {
        active = true; t = 0; vel = velocity; samplePos = 0; level = 1; choking = false
        for i in 0..<6 { ph[i] = 0 }
        bp.reset(); hp.reset(); lp.reset()
    }
    func choke() { choking = true }

    @inline(__always) private func p(_ i: Int) -> Float { owner.param(base + i) }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int, gain: Float) {
        let fs = owner.fs
        let model = Int(p(0).rounded()), tune = semitonesToRatio(p(1)), decay = p(2), tone = p(3), snap = p(4)
        let drive = p(5), lvl = dbToGain(p(6)) * gain * (0.25 + 0.75 * vel), pan = p(7)
        let gl = lvl * min(1, 1 - pan), gr = lvl * min(1, 1 + pan)
        let dt = 1 / fs
        // Configure filters once per block.
        switch model {
        case 1: hp.set(cutoff: 1500 + tone * 3000, resonance: 0.7, sampleRate: fs); bp.set(cutoff: 5000 * tune, resonance: 0.8, sampleRate: fs)
        case 3: bp.set(cutoff: (7000 + tone * 4000) * tune, resonance: 1.2, sampleRate: fs); hp.set(cutoff: 6000 * tune, resonance: 0.7, sampleRate: fs)
        case 4: bp.set(cutoff: (5000 + tone * 4000) * tune, resonance: 0.9, sampleRate: fs); hp.set(cutoff: 3000 * tune, resonance: 0.7, sampleRate: fs)
        case 5: bp.set(cutoff: 1100 + tone * 800, resonance: 2.2, sampleRate: fs)
        case 7: hp.set(cutoff: 7000, resonance: 0.8, sampleRate: fs)
        case 8: bp.set(cutoff: 2000 * tune, resonance: 3, sampleRate: fs)
        case 9: bp.set(cutoff: 2500 * tune, resonance: 1, sampleRate: fs)
        default: lp.set(cutoff: 800 + tone * 6000, resonance: 0.7, sampleRate: fs)
        }
        for i in 0..<frameCount {
            var x: Float = 0
            let time = t
            switch model {
            case 0: // Kick: pitch-swept sine + click
                let f0: Float = 50 * tune
                let f = f0 + f0 * (2 + snap * 6) * expf(-time / 0.03)
                ph[0] += f * dt; if ph[0] >= 1 { ph[0] -= 1 }
                let env = expf(-time / (0.35 * decay))
                let click = time < 0.004 ? lp.lowpass(rng.bipolar()) * (1 - time / 0.004) * (0.3 + tone) : 0
                x = sinf(twoPi * ph[0]) * env + click
                if time > 2.5 * decay + 0.1 { active = false }
            case 1: // Snare: two tones + filtered noise
                ph[0] += 180 * tune * dt; ph[1] += 330 * tune * dt
                if ph[0] >= 1 { ph[0] -= 1 }; if ph[1] >= 1 { ph[1] -= 1 }
                let te = expf(-time / (0.06 * decay))
                let ne = expf(-time / (0.12 * decay * (0.5 + snap)))
                let n = hp.highpass(rng.bipolar()) * 0.7 + bp.bandpass(rng.bipolar()) * 0.5
                x = (sinf(twoPi * ph[0]) * 0.6 + sinf(twoPi * ph[1]) * 0.4) * te * (1 - snap * 0.5) + n * ne * (0.4 + snap)
                if time > 1.2 * decay + 0.1 { active = false }
            case 2: // Tom
                let f0: Float = 110 * tune
                let f = f0 * (1 + 0.6 * expf(-time / 0.05))
                ph[0] += f * dt; if ph[0] >= 1 { ph[0] -= 1 }
                let env = expf(-time / (0.3 * decay))
                x = sinf(twoPi * ph[0]) * env + lp.lowpass(rng.bipolar()) * expf(-time / 0.01) * snap * 0.3
                if time > 2 * decay + 0.1 { active = false }
            case 3, 4: // Hats / cymbals: metallic square cluster + noise
                var m: Float = 0
                for k in 0..<6 {
                    ph[k] += 330 * tune * PadVoice.metallicRatios[k] * dt
                    if ph[k] >= 1 { ph[k] -= 1 }
                    m += ph[k] < 0.5 ? 1 : -1
                }
                let n = rng.bipolar()
                let src = m * (1 - snap * 0.6) / 6 + n * (0.2 + snap * 0.6)
                let tau: Float = model == 3 ? 0.05 * decay : 0.6 * decay
                let env = expf(-time / tau) * (choking ? max(0, 1 - (time * 30)) : 1)
                x = hp.highpass(bp.bandpass(src) * 2 + src * 0.3) * env * 1.5
                if pad == .ride { x += sinf(twoPi * 600 * tune * time) * expf(-time / (0.8 * decay)) * 0.15 * tone }
                if env < 0.0005 || time > 8 { active = false }
            case 5: // Clap: multiple bursts + tail
                let burst = (time < 0.03) ? expf(-fmodf(time, 0.01) / 0.0025) : 0
                let tail = expf(-time / (0.15 * decay))
                x = bp.bandpass(rng.bipolar()) * (burst + tail * (time >= 0.02 ? 1 : 0)) * 2
                if time > 1.5 * decay { active = false }
            case 6: // Rim
                ph[0] += 1700 * tune * dt; if ph[0] >= 1 { ph[0] -= 1 }
                x = (sinf(twoPi * ph[0]) + lp.lowpass(rng.bipolar()) * 0.5) * expf(-time / (0.012 * decay))
                if time > 0.3 { active = false }
            case 7: // Tambourine / shaker
                let jingles = expf(-fmodf(time, 0.018) / 0.006)
                x = hp.highpass(rng.bipolar()) * expf(-time / (0.12 * decay)) * (0.6 + 0.4 * jingles)
                if time > 1 * decay + 0.1 { active = false }
            case 8: // Cowbell
                ph[0] += 540 * tune * dt; ph[1] += 800 * tune * dt
                if ph[0] >= 1 { ph[0] -= 1 }; if ph[1] >= 1 { ph[1] -= 1 }
                let sq = (ph[0] < 0.5 ? 1 : -1) + (ph[1] < 0.5 ? 1 : -1) as Float
                x = bp.bandpass(sq) * expf(-time / (0.15 * decay)) * 1.5
                if time > 1.2 * decay { active = false }
            case 9: // Industrial metal hit: inharmonic partials + noise burst
                var m: Float = 0
                for k in 0..<6 {
                    ph[k] += 220 * tune * PadVoice.metalRatios[k] * dt
                    if ph[k] >= 1 { ph[k] -= 1 }
                    m += sinf(twoPi * ph[k]) * expf(-time * Float(k + 1) / (0.4 * decay)) / Float(k + 1)
                }
                x = m + bp.bandpass(rng.bipolar()) * expf(-time / 0.02) * snap
                if time > 3 * decay { active = false }
            default: // Sample playback
                if sample.isEmpty { active = false; break }
                let idx = Int(samplePos)
                if idx + 1 >= sample.count { active = false; break }
                let fr = Float(samplePos - Double(idx))
                let envD = expf(-time / max(0.05, 2 * decay * decay))
                x = (sample[idx] * (1 - fr) + sample[idx + 1] * fr) * (decay >= 3.9 ? 1 : envD)
                samplePos += Double(tune)
                if choking { level *= 0.995 }
                x *= level
            }
            if drive > 0 { x = lerpf(x, fastTanh(x * (1 + drive * 8)), drive) }
            left[i] += x * gl; right[i] += x * gr
            t += dt
            if !active { break }
        }
    }
}
