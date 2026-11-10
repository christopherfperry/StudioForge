import Foundation
import SFCore

/// Trumpet / brass voice. Physically-inspired rather than a full waveguide: the key brass cues are
/// modelled explicitly — spectral brightness that grows with blowing pressure (amplitude), a lip
/// "scoop" into pitch at the attack, breath noise, delayed vibrato, growl (lip flutter), a bell
/// formant and mute filters (harmon, cup, straight).
public final class BrassInstrument: PolyInstrument {
    public static let mutes = ["Open", "Harmon", "Cup", "Straight"]
    public static let specs: [ParameterSpec] = [
        ParameterSpec("brightness", "Brightness", min: 0, max: 1, default: 0.6, unit: .percent),          // 0
        ParameterSpec("breath", "Breath Noise", min: 0, max: 1, default: 0.2, unit: .percent),            // 1
        ParameterSpec("vibratoRate", "Vibrato Rate", min: 0.5, max: 9, default: 5.2),                     // 2
        ParameterSpec("vibratoDepth", "Vibrato Depth", min: 0, max: 60, default: 18, unit: .cents),       // 3
        ParameterSpec("vibratoDelay", "Vibrato Delay", min: 0, max: 2, default: 0.35, unit: .seconds),    // 4
        ParameterSpec("scoop", "Attack Scoop", min: 0, max: 300, default: 80, unit: .cents),              // 5
        ParameterSpec("attack", "Attack", min: 0.005, max: 0.5, default: 0.04, unit: .seconds, log: true),// 6
        ParameterSpec("release", "Release", min: 0.02, max: 2, default: 0.12, unit: .seconds, log: true), // 7
        .choice("mute", "Mute", mutes),                                                                   // 8
        ParameterSpec("growl", "Growl", min: 0, max: 1, default: 0, unit: .percent),                      // 9
        ParameterSpec("ensemble", "Players", min: 1, max: 3, default: 1),                                 // 10
        ParameterSpec("formant", "Bell Formant", min: 600, max: 2500, default: 1300, unit: .hertz, log: true), // 11
        ParameterSpec("gain", "Volume", min: -36, max: 12, default: -6, unit: .decibels),                 // 12
        ParameterSpec("velocity", "Velocity Sens.", min: 0, max: 1, default: 0.8, unit: .percent),        // 13
    ]
    public init() { super.init(typeID: "brass.trumpet", name: "Trumpet / Brass", specs: Self.specs) }
    public override func makeVoice() -> SynthVoice { Voice(owner: self) }
    public override var voiceCount: Int { 8 }

    final class Voice: SynthVoice {
        unowned let owner: BrassInstrument
        var oscs = [Oscillator(phase: 0), Oscillator(phase: 0.31), Oscillator(phase: 0.67)]
        var noise = Oscillator(seed: 4242)
        var env = ADSR()
        var lp = SVFilter(), formant = SVFilter(), muteF = SVFilter(), muteF2 = SVFilter(), breathF = SVFilter()
        var vib = LFO(), growlLFO = LFO()
        var t: Float = 0
        init(owner: BrassInstrument) { self.owner = owner }
        override var isActive: Bool { env.isActive }
        override func start(note: Int, velocity: Float, legato: Bool) {
            super.start(note: note, velocity: velocity, legato: legato)
            let o = owner
            env.set(attack: o.p(6), decay: 0.25, sustain: 0.85, release: o.p(7), sampleRate: o.fs)
            env.gate(true)
            if !legato { t = 0 }
        }
        override func release() { super.release(); env.gate(false) }
        override func kill() { super.kill(); env.kill() }

        override func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
            let o = owner, fs = o.fs
            let vel = 1 - o.p(13) + o.p(13) * velocity
            let mute = o.pi(8), players = max(1, min(3, o.pi(10)))
            let g = dbToGain(o.p(12)) * 0.35 / sqrtf(Float(players))
            formant.set(cutoff: o.p(11), resonance: 1.8, sampleRate: fs)
            switch mute {
            case 1: muteF.set(cutoff: 1800, resonance: 4, sampleRate: fs); muteF2.set(cutoff: 900, resonance: 0.7, sampleRate: fs)
            case 2: muteF.set(cutoff: 1100, resonance: 1.5, sampleRate: fs); muteF2.set(cutoff: 2500, resonance: 0.7, sampleRate: fs)
            case 3: muteF.set(cutoff: 2600, resonance: 2.5, sampleRate: fs); muteF2.set(cutoff: 700, resonance: 0.7, sampleRate: fs)
            default: break
            }
            breathF.set(cutoff: 3000, resonance: 0.8, sampleRate: fs)
            var i = 0
            while i < frameCount {
                let n = min(16, frameCount - i)
                let a0 = env.value
                // Pitch: scoop at the attack + delayed vibrato + growl flutter
                let scoop = -o.p(5) / 100 * expf(-t / 0.045)
                let vibAmt = min(1, max(0, (t - o.p(4)) / 0.4)) * o.p(3) / 100
                var v: Float = 0, gr: Float = 0
                for _ in 0..<n { v = vib.next(rate: o.p(2), sampleRate: fs); gr = growlLFO.next(rate: 38, sampleRate: fs, shape: .triangle) }
                let pitch = Float(note) + scoop + v * vibAmt + o.bend
                let f = midiToHz(pitch)
                // Brightness tracks blowing pressure (envelope × velocity)
                let pressure = a0 * vel
                let cutoff = f * (1.5 + 14 * o.p(0) * powf(pressure, 1.5)) + 300
                lp.set(cutoff: min(cutoff, fs * 0.45), resonance: 0.9, sampleRate: fs)
                let growlAM = 1 - o.p(9) * 0.5 * (0.5 + 0.5 * gr)
                for k in i..<(i + n) {
                    let e = env.next()
                    var x: Float = 0
                    for pIdx in 0..<players {
                        let det: Float = pIdx == 0 ? 1 : (pIdx == 1 ? 1.0035 : 0.9968)
                        x += oscs[pIdx].next(.saw, dt: f * det / fs) * 0.8
                    }
                    var y = lp.lowpass(x)
                    y = y + formant.bandpass(y) * 0.8
                    y = fastTanh(y * (1 + pressure * 1.5)) * growlAM
                    let br = breathF.bandpass(noise.next(.noise, dt: 0)) * o.p(1) * 0.3 * (0.3 + e)
                    var s = (y + br) * e
                    switch mute {
                    case 1: s = muteF.bandpass(muteF2.highpass(s)) * 2.5
                    case 2: s = muteF2.lowpass(muteF.lowpass(s) + muteF.bandpass(s)) * 1.3
                    case 3: s = muteF.bandpass(s) * 1.5 + muteF2.highpass(s) * 0.6
                    default: break
                    }
                    left[k] += s * g; right[k] += s * g
                }
                t += Float(n) / fs
                i += n
            }
            if !env.isActive { note = -1 }
        }
    }
}
