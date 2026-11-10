import Foundation
import SFCore

/// Virtual-analog subtractive synth: 2 oscillators + sub + noise, unison (up to 7), osc2->osc1 FM,
/// multimode filter with envelope/key tracking/drive, amp & filter ADSR, LFO, glide, mono/legato.
public final class SubtractiveSynth: PolyInstrument {
    static let waves = ["Saw", "Square", "Triangle", "Sine", "Noise"]
    public static let specs: [ParameterSpec] = [
        .choice("osc1Wave", "Osc 1 Wave", waves),                                                    // 0
        ParameterSpec("osc1Level", "Osc 1 Level", min: 0, max: 1, default: 0.8, unit: .percent),     // 1
        ParameterSpec("osc1Octave", "Osc 1 Octave", min: -3, max: 3, default: 0),                    // 2
        ParameterSpec("osc1Detune", "Osc 1 Detune", min: -100, max: 100, default: 0, unit: .cents),  // 3
        .choice("osc2Wave", "Osc 2 Wave", waves, default: 1),                                        // 4
        ParameterSpec("osc2Level", "Osc 2 Level", min: 0, max: 1, default: 0.5, unit: .percent),     // 5
        ParameterSpec("osc2Octave", "Osc 2 Octave", min: -3, max: 3, default: 0),                    // 6
        ParameterSpec("osc2Semi", "Osc 2 Semitone", min: -12, max: 12, default: 0, unit: .semitones),// 7
        ParameterSpec("osc2Detune", "Osc 2 Detune", min: -100, max: 100, default: 7, unit: .cents),  // 8
        ParameterSpec("subLevel", "Sub Osc", min: 0, max: 1, default: 0, unit: .percent),            // 9
        ParameterSpec("noiseLevel", "Noise", min: 0, max: 1, default: 0, unit: .percent),            // 10
        ParameterSpec("unison", "Unison Voices", min: 1, max: 7, default: 1),                        // 11
        ParameterSpec("unisonDetune", "Unison Detune", min: 0, max: 100, default: 15, unit: .cents), // 12
        ParameterSpec("fmAmount", "FM (Osc2→Osc1)", min: 0, max: 5, default: 0),                     // 13
        ParameterSpec("pulseWidth", "Pulse Width", min: 0.05, max: 0.95, default: 0.5),              // 14
        .choice("filterType", "Filter", ["Low Pass 24", "Low Pass 12", "High Pass", "Band Pass"]),   // 15
        ParameterSpec("cutoff", "Cutoff", min: 20, max: 20000, default: 3000, unit: .hertz, log: true), // 16
        ParameterSpec("resonance", "Resonance", min: 0.5, max: 10, default: 1, log: true),          // 17
        ParameterSpec("filterEnv", "Filter Env Amount", min: -1, max: 1, default: 0.3),             // 18
        ParameterSpec("keyTrack", "Key Tracking", min: 0, max: 1, default: 0.5, unit: .percent),     // 19
        ParameterSpec("filterDrive", "Filter Drive", min: 0, max: 24, default: 0, unit: .decibels),  // 20
        ParameterSpec("ampA", "Amp Attack", min: 0.001, max: 5, default: 0.005, unit: .seconds, log: true), // 21
        ParameterSpec("ampD", "Amp Decay", min: 0.001, max: 5, default: 0.3, unit: .seconds, log: true),    // 22
        ParameterSpec("ampS", "Amp Sustain", min: 0, max: 1, default: 0.8, unit: .percent),                 // 23
        ParameterSpec("ampR", "Amp Release", min: 0.001, max: 8, default: 0.25, unit: .seconds, log: true), // 24
        ParameterSpec("filtA", "Filter Attack", min: 0.001, max: 5, default: 0.005, unit: .seconds, log: true), // 25
        ParameterSpec("filtD", "Filter Decay", min: 0.001, max: 5, default: 0.4, unit: .seconds, log: true),    // 26
        ParameterSpec("filtS", "Filter Sustain", min: 0, max: 1, default: 0.3, unit: .percent),                 // 27
        ParameterSpec("filtR", "Filter Release", min: 0.001, max: 8, default: 0.3, unit: .seconds, log: true),  // 28
        ParameterSpec("lfoRate", "LFO Rate", min: 0.01, max: 30, default: 4, log: true),             // 29
        .choice("lfoShape", "LFO Shape", ["Sine", "Triangle", "Square", "Saw", "Random"]),          // 30
        ParameterSpec("lfoPitch", "LFO → Pitch", min: 0, max: 12, default: 0, unit: .semitones),     // 31
        ParameterSpec("lfoCutoff", "LFO → Cutoff", min: 0, max: 4, default: 0),                      // 32
        ParameterSpec("lfoAmp", "LFO → Amp", min: 0, max: 1, default: 0, unit: .percent),            // 33
        ParameterSpec("glide", "Glide", min: 0, max: 1000, default: 0, unit: .milliseconds),         // 34
        .toggle("mono", "Mono / Legato"),                                                            // 35
        ParameterSpec("velocity", "Velocity Sens.", min: 0, max: 1, default: 0.7, unit: .percent),   // 36
        ParameterSpec("gain", "Volume", min: -36, max: 12, default: -6, unit: .decibels),            // 37
        ParameterSpec("drive", "Output Drive", min: 0, max: 1, default: 0, unit: .percent),          // 38
        ParameterSpec("spread", "Stereo Spread", min: 0, max: 1, default: 0.6, unit: .percent),      // 39
    ]

    public init(typeID: String = "synth.subtractive", name: String = "Subtractive Synth", defaults: [String: Float] = [:]) {
        super.init(typeID: typeID, name: name, specs: Self.specs, defaults: defaults)
    }

    /// Bass flavour: mono, sub oscillator, drive, darker filter.
    public static func bass() -> SubtractiveSynth {
        SubtractiveSynth(typeID: "synth.bass", name: "Bass Synth", defaults: [
            "mono": 1, "subLevel": 0.6, "osc1Octave": -1, "osc2Octave": -1, "osc2Level": 0.4, "cutoff": 700,
            "filterEnv": 0.45, "resonance": 1.4, "drive": 0.3, "ampR": 0.08, "glide": 20, "spread": 0, "osc2Detune": 4,
        ])
    }

    public override var isMono: Bool { parameters.all[35].value >= 0.5 }
    public override var voiceCount: Int { 16 }
    public override func makeVoice() -> SynthVoice { Voice(synth: self) }

    final class Voice: SynthVoice {
        unowned let synth: SubtractiveSynth
        var osc1 = [Oscillator](), osc2 = [Oscillator]()
        var sub = Oscillator(), noise = Oscillator(seed: 99)
        var amp = ADSR(), filt = ADSR()
        var f1 = SVFilter(), f2 = SVFilter()
        var lfo = LFO()
        var currentPitch: Float = 60
        var targetPitch: Float = 60
        var dets = [Float](repeating: 1, count: 7)
        var pans = [Float](repeating: 0.5, count: 7)
        init(synth: SubtractiveSynth) {
            self.synth = synth
            super.init()
            var rng = FastRandom(seed: UInt32.random(in: 1...UInt32.max))
            osc1 = (0..<7).map { _ in Oscillator(phase: rng.unipolar()) }
            osc2 = (0..<7).map { _ in Oscillator(phase: rng.unipolar()) }
        }
        override var isActive: Bool { amp.isActive }
        override func start(note: Int, velocity: Float, legato: Bool) {
            let s = synth
            amp.set(attack: s.p(21), decay: s.p(22), sustain: s.p(23), release: s.p(24), sampleRate: s.fs)
            filt.set(attack: s.p(25), decay: s.p(26), sustain: s.p(27), release: s.p(28), sampleRate: s.fs)
            targetPitch = Float(note)
            if !legato && (s.p(34) <= 0 || !isActive) { currentPitch = targetPitch }
            if !legato { amp.gate(true); filt.gate(true) }
            super.start(note: note, velocity: velocity, legato: legato)
        }
        override func release() { super.release(); amp.gate(false); filt.gate(false) }
        override func kill() { super.kill(); amp.kill(); filt.kill() }

        override func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
            let s = synth, fs = s.fs
            let w1 = Oscillator.Wave(rawValue: s.pi(0)) ?? .saw, w2 = Oscillator.Wave(rawValue: s.pi(4)) ?? .square
            let l1 = s.p(1), l2 = s.p(5), subL = s.p(9), noiseL = s.p(10)
            let uni = max(1, min(7, s.pi(11))), uniDet = s.p(12), fm = s.p(13), pw = s.p(14)
            let ftype = s.pi(15), res = s.p(17), envAmt = s.p(18) * 6, keyT = s.p(19), fdrive = dbToGain(s.p(20))
            let lfoShape = LFO.Shape(rawValue: s.pi(30)) ?? .sine
            let vel = 1 - s.p(36) + s.p(36) * velocity
            let gain = dbToGain(s.p(37)) * vel / sqrtf(Float(uni)), drive = s.p(38), spread = s.p(39)
            let glideCoef = s.p(34) > 0 ? onePoleCoef(seconds: s.p(34) / 1000 / 3, sampleRate: fs) : 0
            let oct1 = s.p(2) * 12 + s.p(3) / 100, oct2 = s.p(6) * 12 + s.p(7) + s.p(8) / 100
            var i = 0
            while i < frameCount {
                let n = min(16, frameCount - i)
                // Control-rate updates every 16 samples.
                var lfoV: Float = 0
                for _ in 0..<n { lfoV = lfo.next(rate: s.p(29), sampleRate: fs, shape: lfoShape) }
                for _ in 0..<n { currentPitch = targetPitch + glideCoef * (currentPitch - targetPitch) }
                let pitch = currentPitch + s.bend + lfoV * (s.p(31) + s.modWheel * 0.5)
                let fEnv = filt.value
                let cutoff = s.p(16) * powf(2, envAmt * fEnv + lfoV * s.p(32) + keyT * (pitch - 60) / 12)
                if ftype <= 1 {
                    f1.set(cutoff: cutoff, resonance: ftype == 0 ? max(0.5, res * 0.7) : res, sampleRate: fs)
                    f2.set(cutoff: cutoff, resonance: res, sampleRate: fs)
                } else { f1.set(cutoff: cutoff, resonance: res, sampleRate: fs) }
                let base1 = midiToHz(pitch + oct1), base2 = midiToHz(pitch + oct2), baseSub = midiToHz(pitch - 12)
                for u in 0..<uni {
                    let off: Float = uni == 1 ? 0 : (Float(u) / Float(uni - 1) - 0.5) * 2
                    dets[u] = semitonesToRatio(off * uniDet / 100)
                    pans[u] = 0.5 + off * 0.5 * spread
                }
                for k in i..<(i + n) {
                    let a = amp.next(); _ = filt.next()
                    var l: Float = 0, r: Float = 0
                    for u in 0..<uni {
                        let det = dets[u]
                        let o2 = osc2[u].next(w2, dt: base2 * det / fs, pw: pw)
                        let o1 = osc1[u].next(w1, dt: base1 * det / fs, pw: pw, pm: fm * o2 * 0.25)
                        let v = o1 * l1 + o2 * l2 * (fm > 0 ? 0.3 : 1)
                        let pan = pans[u]
                        l += v * (1 - pan) * 2; r += v * pan * 2
                    }
                    let common = sub.next(.sine, dt: baseSub / fs) * subL + noise.next(.noise, dt: 0) * noiseL
                    l = (l * 0.5 + common) * fdrive; r = (r * 0.5 + common) * fdrive
                    if fdrive > 1.01 { l = fastTanh(l); r = fastTanh(r) }
                    // Mono filter path on mid/side keeps CPU low; stereo image preserved via side passthrough.
                    let mid = (l + r) * 0.5, side = (l - r) * 0.5
                    var y: Float
                    switch ftype {
                    case 0: y = f2.lowpass(f1.lowpass(mid))
                    case 1: y = f1.lowpass(mid)
                    case 2: y = f1.highpass(mid)
                    default: y = f1.bandpass(mid)
                    }
                    let sideF = side * min(1, cutoff / 8000)
                    let ampMod = 1 - s.p(33) * (0.5 + 0.5 * lfoV)
                    var outL = (y + sideF) * a * gain * ampMod, outR = (y - sideF) * a * gain * ampMod
                    if drive > 0 { outL = lerpf(outL, fastTanh(outL * (1 + drive * 6)), drive); outR = lerpf(outR, fastTanh(outR * (1 + drive * 6)), drive) }
                    left[k] += outL; right[k] += outR
                }
                i += n
            }
            if !amp.isActive { note = -1 }
        }
    }
}
