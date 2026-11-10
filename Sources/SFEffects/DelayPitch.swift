import Foundation
import SFCore

/// Stereo / ping-pong delay with tempo sync, filtered and saturated feedback and modulation.
public final class StereoDelay: EffectBase {
    public static let syncDivisions = ["Off (ms)", "1/2", "1/4", "1/4 Dotted", "1/8", "1/8 Dotted", "1/8 Triplet", "1/16"]
    private static let syncBeats: [Double] = [0, 2, 1, 1.5, 0.5, 0.75, 1.0 / 3.0, 0.25]
    public static let specs: [ParameterSpec] = [
        ParameterSpec("time", "Time", min: 1, max: 2000, default: 380, unit: .milliseconds, log: true),
        .choice("sync", "Sync", syncDivisions, default: 0),
        ParameterSpec("feedback", "Feedback", min: 0, max: 0.98, default: 0.35, unit: .percent),
        ParameterSpec("wet", "Wet", min: 0, max: 1, default: 0.3, unit: .percent),
        .toggle("pingpong", "Ping-Pong"),
        ParameterSpec("lowCut", "FB Low Cut", min: 20, max: 2000, default: 120, unit: .hertz, log: true),
        ParameterSpec("highCut", "FB High Cut", min: 1000, max: 20000, default: 6000, unit: .hertz, log: true),
        ParameterSpec("modDepth", "Modulation", min: 0, max: 1, default: 0.1, unit: .percent),
        ParameterSpec("drive", "Tape Drive", min: 0, max: 1, default: 0, unit: .percent),
        ParameterSpec("offsetR", "R Offset", min: -0.5, max: 0.5, default: 0, unit: .percent),
    ]
    private var dl = DelayLine(maxDelaySamples: 1 << 17), dr = DelayLine(maxDelaySamples: 1 << 17)
    private var hpL = OnePole(), hpR = OnePole(), lpL = OnePole(), lpR = OnePole()
    private var lfo = LFO()
    private var time = Smoothed(0)
    public init() { super.init(typeID: "delay", name: "Delay", specs: Self.specs) }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        dl = DelayLine(maxDelaySamples: Int(sampleRate * 4.2)); dr = DelayLine(maxDelaySamples: Int(sampleRate * 4.2))
        time.snap(p(0) / 1000 * fs)
    }
    public override func reset() { dl.clear(); dr.clear() }

    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let sync = pi(1)
        var tSamples = p(0) / 1000 * fs
        if sync > 0 && sync < Self.syncBeats.count {
            let bpm = max(20, HostContext.shared.tempo.value)
            tSamples = Float(Self.syncBeats[sync] * 60 / bpm) * fs
        }
        tSamples = min(tSamples, Float(dl.maxDelay) / 1.6)
        time.setTarget(tSamples, rampSamples: Int(fs * 0.05))
        hpL.setCutoff(p(5), sampleRate: fs); hpR.setCutoff(p(5), sampleRate: fs)
        lpL.setCutoff(p(6), sampleRate: fs); lpR.setCutoff(p(6), sampleRate: fs)
        let fb = p(2), wet = p(3), ping = p(4) >= 0.5, mod = p(7) * fs * 0.002, drive = p(8), off = 1 + p(9)
        for i in 0..<frameCount {
            let t = time.next()
            let m = lfo.next(rate: 0.6, sampleRate: fs) * mod
            var yl = dl.read(cubic: t + m)
            var yr = dr.read(cubic: t * off - m)
            yl = lpL.lowpass(hpL.highpass(yl)); yr = lpR.lowpass(hpR.highpass(yr))
            if drive > 0 { yl = lerpf(yl, fastTanh(yl * (1 + drive * 3)), drive); yr = lerpf(yr, fastTanh(yr * (1 + drive * 3)), drive) }
            let xl = left[i], xr = right[i]
            if ping {
                dl.write((xl + xr) * 0.5 + yr * fb)
                dr.write(yl * fb)
            } else {
                dl.write(xl + yl * fb); dr.write(xr + yr * fb)
            }
            left[i] = xl + yl * wet; right[i] = xr + yr * wet
        }
    }
}

/// Granular two-tap pitch shifter (real-time, low CPU). Used for pitch shift, octave up/down
/// layers, harmonies and the shimmer reverb feedback path.
public struct PitchShiftCore {
    private var line: DelayLine
    private var phase: Float = 0
    public init(maxSamples: Int) { line = DelayLine(maxDelaySamples: maxSamples) }
    public mutating func clear() { line.clear() }
    /// `window` in samples. ratio > 1 shifts up.
    @inline(__always) public mutating func process(_ x: Float, ratio: Float, window: Float) -> Float {
        line.write(x)
        phase += (1 - ratio) / window
        if phase >= 1 { phase -= 1 } else if phase < 0 { phase += 1 }
        let p2 = phase + 0.5 >= 1 ? phase - 0.5 : phase + 0.5
        let d1 = 2 + phase * window, d2 = 2 + p2 * window
        let g1 = sinf(Float.pi * phase), g2 = sinf(Float.pi * p2)
        return line.read(fractional: d1) * g1 + line.read(fractional: d2) * g2
    }
}

public final class PitchShifter: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("semitones", "Pitch", min: -24, max: 24, default: -12, unit: .semitones),
        ParameterSpec("cents", "Fine", min: -100, max: 100, default: 0, unit: .cents),
        ParameterSpec("window", "Grain", min: 15, max: 120, default: 50, unit: .milliseconds),
        ParameterSpec("wet", "Wet", min: 0, max: 1, default: 0.5, unit: .percent),
        ParameterSpec("detuneR", "R Detune", min: -50, max: 50, default: 0, unit: .cents),
    ]
    private var l = PitchShiftCore(maxSamples: 16384), r = PitchShiftCore(maxSamples: 16384)
    public init() { super.init(typeID: "pitchshift", name: "Pitch Shifter", specs: Self.specs) }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        l = PitchShiftCore(maxSamples: Int(sampleRate * 0.25)); r = PitchShiftCore(maxSamples: Int(sampleRate * 0.25))
    }
    public override func reset() { l.clear(); r.clear() }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        let ratioL = semitonesToRatio(p(0) + p(1) / 100)
        let ratioR = semitonesToRatio(p(0) + (p(1) + p(4)) / 100)
        let w = p(2) / 1000 * fs, wet = p(3)
        for i in 0..<frameCount {
            let yl = l.process(left[i], ratio: ratioL, window: w)
            let yr = r.process(right[i], ratio: ratioR, window: w)
            left[i] = left[i] * (1 - wet) + yl * wet
            right[i] = right[i] * (1 - wet) + yr * wet
        }
    }
}

/// Analog-style octaver: flip-flop sub-octaves (-1, -2) tracking the input envelope plus a
/// rectifier octave-up — classic for bass and fuzz guitar.
public final class Octaver: EffectBase {
    public static let specs: [ParameterSpec] = [
        ParameterSpec("dry", "Dry", min: 0, max: 1, default: 1, unit: .percent),
        ParameterSpec("sub1", "Octave Down", min: 0, max: 1, default: 0.6, unit: .percent),
        ParameterSpec("sub2", "Two Octaves Down", min: 0, max: 1, default: 0, unit: .percent),
        ParameterSpec("up", "Octave Up", min: 0, max: 1, default: 0, unit: .percent),
        ParameterSpec("tone", "Tone", min: 200, max: 5000, default: 900, unit: .hertz, log: true),
    ]
    private var detect = SVFilter()
    private var env = EnvelopeFollower()
    private var lastSign: Float = 1
    private var ff1: Float = 1, ff2: Float = 1
    private var toneL = OnePole(), toneR = OnePole()
    private var dc = DCBlocker()
    public init() { super.init(typeID: "octaver", name: "Octaver", specs: Self.specs) }
    public override func prepare(sampleRate: Double, maxFrames: Int) {
        super.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
        detect.set(cutoff: 300, resonance: 0.6, sampleRate: fs)
        env.set(attackMs: 2, releaseMs: 60, sampleRate: fs)
    }
    public override func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        toneL.setCutoff(p(4), sampleRate: fs); toneR.setCutoff(p(4), sampleRate: fs)
        let dry = p(0), s1 = p(1), s2 = p(2), up = p(3)
        for i in 0..<frameCount {
            let x = (left[i] + right[i]) * 0.5
            let lp = detect.lowpass(x)
            let e = env.process(x)
            let sign: Float = lp >= 0 ? 1 : -1
            if sign > 0 && lastSign < 0 { ff1 = -ff1; if ff1 > 0 { ff2 = -ff2 } }
            lastSign = sign
            let oct = dc.process(abs(x) * 2 - e)
            let sub = (ff1 * s1 + ff2 * s2) * e * 1.4
            let wetL = toneL.lowpass(sub) + oct * up
            let wetR = toneR.lowpass(sub) + oct * up
            left[i] = left[i] * dry + wetL
            right[i] = right[i] * dry + wetR
        }
    }
}
