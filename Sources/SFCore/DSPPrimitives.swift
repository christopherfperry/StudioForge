import Foundation

// MARK: - Math helpers

@inline(__always) public func dbToGain(_ db: Float) -> Float { db <= -120 ? 0 : powf(10, db / 20) }
@inline(__always) public func gainToDb(_ g: Float) -> Float { g <= 1e-6 ? -120 : 20 * log10f(g) }
@inline(__always) public func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }
@inline(__always) public func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) public func midiToHz(_ note: Float) -> Float { 440 * powf(2, (note - 69) / 12) }
@inline(__always) public func semitonesToRatio(_ s: Float) -> Float { powf(2, s / 12) }
/// Fast rational tanh approximation (accurate to ~1e-3, saturates smoothly at ±1).
@inline(__always) public func fastTanh(_ x: Float) -> Float {
    if x > 4.97 { return 1 }
    if x < -4.97 { return -1 }
    let x2 = x * x
    let a = x * (135135 + x2 * (17325 + x2 * (378 + x2)))
    let b = 135135 + x2 * (62370 + x2 * (3150 + x2 * 28))
    return a / b
}
/// One-pole coefficient for a time constant in seconds.
@inline(__always) public func onePoleCoef(seconds: Float, sampleRate: Float) -> Float {
    seconds <= 0 ? 0 : expf(-1 / (seconds * sampleRate))
}
public let twoPi: Float = 2 * Float.pi

/// Real-time safe pseudo random generator (xorshift32). No allocation, no locks.
public struct FastRandom {
    private var state: UInt32
    public init(seed: UInt32 = 0x1234_5678) { state = seed == 0 ? 0x9E37_79B9 : seed }
    @inline(__always) public mutating func next() -> UInt32 {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return state
    }
    /// Uniform in [-1, 1).
    @inline(__always) public mutating func bipolar() -> Float { Float(Int32(bitPattern: next())) / 2_147_483_648.0 }
    /// Uniform in [0, 1).
    @inline(__always) public mutating func unipolar() -> Float { Float(next() >> 8) / 16_777_216.0 }
}

/// Deterministic 64-bit generator for non-real-time code (beat generation, IR synthesis).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

// MARK: - Biquad (RBJ cookbook, transposed direct form II)

public struct BiquadCoefficients: Equatable {
    public var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    public init() {}
    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    public enum Kind: Int, Codable, CaseIterable { case lowpass, highpass, bandpass, notch, peak, lowShelf, highShelf, allpass }

    public static func make(_ kind: Kind, freq: Float, q: Float, gainDB: Float = 0, sampleRate: Float) -> BiquadCoefficients {
        let f = clampf(freq, 5, sampleRate * 0.49)
        let w0 = twoPi * f / sampleRate
        let cw = cosf(w0), sw = sinf(w0)
        let qq = max(q, 0.025)
        let alpha = sw / (2 * qq)
        let A = powf(10, gainDB / 40)
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a0: Float = 1, a1: Float = 0, a2: Float = 0
        switch kind {
        case .lowpass:
            b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .highpass:
            b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .bandpass:
            b0 = alpha; b1 = 0; b2 = -alpha; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cw; b2 = 1; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrtf(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cw + s); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - s)
            a0 = (A + 1) + (A - 1) * cw + s; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - s
        case .highShelf:
            let s = 2 * sqrtf(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cw + s); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - s)
            a0 = (A + 1) - (A - 1) * cw + s; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - s
        case .allpass:
            b0 = 1 - alpha; b1 = -2 * cw; b2 = 1 + alpha; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Magnitude response at a frequency (used by tests and EQ curve drawing).
    public func magnitude(at freq: Float, sampleRate: Float) -> Float {
        let w = Double(twoPi * freq / sampleRate)
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = Double(b0) + Double(b1) * c1 + Double(b2) * c2
        let ni = -(Double(b1) * s1 + Double(b2) * s2)
        let dr = 1 + Double(a1) * c1 + Double(a2) * c2
        let di = -(Double(a1) * s1 + Double(a2) * s2)
        return Float(sqrt((nr * nr + ni * ni) / (dr * dr + di * di)))
    }
}

public struct Biquad {
    public var c = BiquadCoefficients()
    private var z1: Float = 0, z2: Float = 0
    public init() {}
    public init(_ c: BiquadCoefficients) { self.c = c }
    @inline(__always) public mutating func process(_ x: Float) -> Float {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
    public mutating func process(_ buf: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count { buf[i] = process(buf[i]) }
    }
    public mutating func reset() { z1 = 0; z2 = 0 }
}

// MARK: - State variable filter (Cytomic / Simper TPT form) — stable under fast modulation.

public struct SVFilter {
    private var ic1: Float = 0, ic2: Float = 0
    private var a1: Float = 1, a2: Float = 0, a3: Float = 0, k: Float = 1
    public private(set) var low: Float = 0, band: Float = 0, high: Float = 0
    public init() {}
    @inline(__always) public mutating func set(cutoff: Float, resonance q: Float, sampleRate: Float) {
        let fc = clampf(cutoff, 10, sampleRate * 0.47)
        let g = tanf(Float.pi * fc / sampleRate)
        k = 1 / max(q, 0.3)
        a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
    }
    @inline(__always) public mutating func tick(_ v0: Float) {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        low = v2; band = v1; high = v0 - k * v1 - v2
    }
    @inline(__always) public mutating func lowpass(_ x: Float) -> Float { tick(x); return low }
    @inline(__always) public mutating func highpass(_ x: Float) -> Float { tick(x); return high }
    @inline(__always) public mutating func bandpass(_ x: Float) -> Float { tick(x); return band }
    @inline(__always) public mutating func notch(_ x: Float) -> Float { tick(x); return low + high }
    public mutating func reset() { ic1 = 0; ic2 = 0; low = 0; band = 0; high = 0 }
}

/// Simple one-pole lowpass / DC blocker.
public struct OnePole {
    public var coef: Float = 0
    private var z: Float = 0
    public init() {}
    public mutating func setCutoff(_ hz: Float, sampleRate: Float) { coef = expf(-twoPi * clampf(hz, 1, sampleRate * 0.49) / sampleRate) }
    @inline(__always) public mutating func lowpass(_ x: Float) -> Float { z = x + coef * (z - x); return z }
    @inline(__always) public mutating func highpass(_ x: Float) -> Float { x - lowpass(x) }
    public mutating func reset() { z = 0 }
}

public struct DCBlocker {
    private var x1: Float = 0, y1: Float = 0
    public init() {}
    @inline(__always) public mutating func process(_ x: Float) -> Float {
        let y = x - x1 + 0.995 * y1
        x1 = x; y1 = abs(y) < 1e-20 ? 0 : y
        return y1
    }
}

/// First-order allpass (phasers / dispersion).
public struct FirstOrderAllpass {
    private var z: Float = 0
    public init() {}
    @inline(__always) public mutating func process(_ x: Float, a: Float) -> Float {
        let y = -a * x + z
        z = x + a * y
        return y
    }
    public mutating func reset() { z = 0 }
}

/// Envelope follower with separate attack/release.
public struct EnvelopeFollower {
    public var attackCoef: Float = 0.9
    public var releaseCoef: Float = 0.999
    public private(set) var value: Float = 0
    public init() {}
    public mutating func set(attackMs: Float, releaseMs: Float, sampleRate: Float) {
        attackCoef = onePoleCoef(seconds: attackMs / 1000, sampleRate: sampleRate)
        releaseCoef = onePoleCoef(seconds: releaseMs / 1000, sampleRate: sampleRate)
    }
    @inline(__always) public mutating func process(_ x: Float) -> Float {
        let a = abs(x)
        let c = a > value ? attackCoef : releaseCoef
        value = a + c * (value - a)
        return value
    }
    public mutating func reset() { value = 0 }
}

/// Low-frequency oscillator.
public struct LFO {
    public enum Shape: Int { case sine, triangle, square, saw, randomHold }
    public var phase: Float = 0
    private var held: Float = 0
    private var rng = FastRandom(seed: 0xA5A5_1234)
    public init(phase: Float = 0) { self.phase = phase }
    @inline(__always) public mutating func next(rate: Float, sampleRate: Float, shape: Shape = .sine) -> Float {
        let out: Float
        switch shape {
        case .sine: out = sinf(twoPi * phase)
        case .triangle: out = 4 * abs(phase - 0.5) - 1
        case .square: out = phase < 0.5 ? 1 : -1
        case .saw: out = 2 * phase - 1
        case .randomHold: out = held
        }
        phase += rate / sampleRate
        if phase >= 1 { phase -= floorf(phase); held = rng.bipolar() }
        return out
    }
}

/// Linear parameter smoother (per block ramps; no zipper noise).
public struct Smoothed {
    public private(set) var current: Float
    private var target: Float
    private var step: Float = 0
    private var remaining = 0
    public init(_ v: Float) { current = v; target = v }
    public mutating func setTarget(_ v: Float, rampSamples: Int) {
        if v == target { return }
        target = v
        remaining = max(1, rampSamples)
        step = (target - current) / Float(remaining)
    }
    public mutating func snap(_ v: Float) { current = v; target = v; remaining = 0 }
    @inline(__always) public mutating func next() -> Float {
        if remaining > 0 { current += step; remaining -= 1; if remaining == 0 { current = target } }
        return current
    }
}

// MARK: - Delay line with fractional read

public final class DelayLine {
    private let buffer: UnsafeMutablePointer<Float>
    private let size: Int
    private let mask: Int
    private var writePos = 0

    public init(maxDelaySamples: Int) {
        var s = 2
        while s < maxDelaySamples + 4 { s <<= 1 }
        size = s; mask = s - 1
        buffer = .allocate(capacity: s)
        buffer.initialize(repeating: 0, count: s)
    }
    deinit { buffer.deallocate() }

    public var maxDelay: Int { size - 4 }

    @inline(__always) public func write(_ x: Float) {
        buffer[writePos] = x
        writePos = (writePos + 1) & mask
    }
    /// Integer delay read (delay >= 1 means the sample written `delay` writes ago).
    @inline(__always) public func read(_ delay: Int) -> Float {
        buffer[(writePos - max(1, min(delay, size - 1))) & mask]
    }
    /// Fractional delay (linear interpolation).
    @inline(__always) public func read(fractional delay: Float) -> Float {
        let d = clampf(delay, 1, Float(size - 3))
        let di = Int(d)
        let frac = d - Float(di)
        let a = buffer[(writePos - di) & mask]
        let b = buffer[(writePos - di - 1) & mask]
        return a + (b - a) * frac
    }
    /// Cubic (Hermite) interpolated read for modulated effects.
    @inline(__always) public func read(cubic delay: Float) -> Float {
        let d = clampf(delay, 2, Float(size - 4))
        let di = Int(d)
        let t = d - Float(di)
        let y0 = buffer[(writePos - di + 1) & mask]
        let y1 = buffer[(writePos - di) & mask]
        let y2 = buffer[(writePos - di - 1) & mask]
        let y3 = buffer[(writePos - di - 2) & mask]
        let c0 = y1
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + c0
    }
    public func clear() { buffer.update(repeating: 0, count: size) }
}

/// Schroeder allpass diffuser built on a delay line.
public final class AllpassDiffuser {
    private let line: DelayLine
    public var delay: Float
    public var gain: Float
    public init(maxDelay: Int, delay: Float, gain: Float) {
        line = DelayLine(maxDelaySamples: maxDelay)
        self.delay = delay; self.gain = gain
    }
    @inline(__always) public func process(_ x: Float) -> Float {
        let d = line.read(fractional: delay)
        let v = x + gain * d
        line.write(v)
        return d - gain * v
    }
    public func clear() { line.clear() }
}

// MARK: - Buffer helpers

/// Pre-allocated scratch buffer for the audio thread.
public final class ScratchBuffer {
    public let capacity: Int
    public let data: UnsafeMutablePointer<Float>
    public init(capacity: Int) {
        self.capacity = capacity
        data = .allocate(capacity: capacity)
        data.initialize(repeating: 0, count: capacity)
    }
    deinit { data.deallocate() }
    @inline(__always) public func clear(_ n: Int) { data.update(repeating: 0, count: min(n, capacity)) }
}

public enum BufferOps {
    @inline(__always) public static func peak(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
        var m: Float = 0
        for i in 0..<n { m = max(m, abs(p[i])) }
        return m
    }
    @inline(__always) public static func rms(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
        if n == 0 { return 0 }
        var s: Float = 0
        for i in 0..<n { s += p[i] * p[i] }
        return sqrtf(s / Float(n))
    }
    @inline(__always) public static func add(_ src: UnsafePointer<Float>, into dst: UnsafeMutablePointer<Float>, _ n: Int, gain: Float = 1) {
        for i in 0..<n { dst[i] += src[i] * gain }
    }
    @inline(__always) public static func scale(_ p: UnsafeMutablePointer<Float>, _ n: Int, _ g: Float) {
        for i in 0..<n { p[i] *= g }
    }
    /// Replaces NaN/Inf with 0 — a safety net so a misbehaving plugin can't blow up the mix.
    @inline(__always) public static func sanitize(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n where !p[i].isFinite { p[i] = 0 }
    }
}
