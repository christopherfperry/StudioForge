import Foundation
import SFCore

/// A playable sound source driven by note events. Rendering is real-time safe.
public protocol Instrument: AnyObject {
    var typeID: String { get }
    var displayName: String { get }
    var parameters: ParameterSet { get }
    func prepare(sampleRate: Double, maxFrames: Int)
    func noteOn(note: Int, velocity: Float)
    func noteOff(note: Int)
    func allNotesOff(hard: Bool)
    func pitchBend(semitones: Float)
    func controlChange(_ cc: Int, value: Float)
    /// Renders (overwrites) `frameCount` stereo samples.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int)
    func setExtra(_ key: String, value: String)
    var extras: [String: String] { get }
}

public extension Instrument {
    var state: InstrumentState { InstrumentState(type: typeID, params: parameters.snapshot(), extra: extras) }
}

/// A voice of a polyphonic instrument.
open class SynthVoice {
    public var note: Int = -1
    public var velocity: Float = 0
    public var age: Int = 0
    public var releasing = false
    public init() {}
    open var isActive: Bool { false }
    open func start(note: Int, velocity: Float, legato: Bool) { self.note = note; self.velocity = velocity; releasing = false }
    open func release() { releasing = true }
    open func kill() { note = -1 }
    /// Adds into the buffers.
    open func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {}
}

/// Base class providing voice allocation (oldest-first stealing), sustain pedal and pitch bend.
open class PolyInstrument: Instrument {
    public let typeID: String
    public let displayName: String
    public let parameters: ParameterSet
    public private(set) var sampleRate: Double = 48_000
    public private(set) var maxFrames = 4096
    public private(set) var extras: [String: String] = [:]
    public var voices: [SynthVoice] = []
    public var bend: Float = 0
    public var modWheel: Float = 0
    private var sustain = false
    private var sustained = Set<Int>(minimumCapacity: 128)
    private var counter = 0
    public var fs: Float { Float(sampleRate) }
    /// When true, only one voice sounds (legato/glide handled by the voice).
    open var isMono: Bool { false }

    public init(typeID: String, name: String, specs: [ParameterSpec], defaults: [String: Float] = [:]) {
        self.typeID = typeID
        displayName = name
        parameters = ParameterSet(specs)
        parameters.apply(defaults)
    }

    open func makeVoice() -> SynthVoice { SynthVoice() }
    open var voiceCount: Int { 16 }

    open func prepare(sampleRate: Double, maxFrames: Int) {
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        voices = (0..<voiceCount).map { _ in makeVoice() }
    }

    open func noteOn(note: Int, velocity: Float) {
        guard !voices.isEmpty else { return }
        counter += 1
        sustained.remove(note)
        if isMono {
            let v = voices[0]
            let legato = v.isActive && !v.releasing
            v.start(note: note, velocity: velocity, legato: legato)
            v.age = counter
            return
        }
        // Retrigger same note if already sounding.
        // Allocation-free voice selection: same note > free voice > oldest releasing > oldest.
        var chosen: SynthVoice?
        var oldestReleasing: SynthVoice?
        var oldest = voices[0]
        for v in voices {
            if v.note == note && v.isActive { chosen = v; break }
            if !v.isActive { if chosen == nil { chosen = v } ; continue }
            if v.releasing && (oldestReleasing == nil || v.age < oldestReleasing!.age) { oldestReleasing = v }
            if v.age < oldest.age { oldest = v }
        }
        let v = chosen ?? oldestReleasing ?? oldest
        v.start(note: note, velocity: velocity, legato: false)
        v.age = counter
    }

    open func noteOff(note: Int) {
        if sustain { sustained.insert(note); return }
        for v in voices where v.note == note && v.isActive && !v.releasing { v.release() }
    }

    open func allNotesOff(hard: Bool) {
        sustained.removeAll(keepingCapacity: true)
        for v in voices { if hard { v.kill() } else { v.release() } }
    }

    open func pitchBend(semitones: Float) { bend = semitones }

    open func controlChange(_ cc: Int, value: Float) {
        switch cc {
        case 1: modWheel = value
        case 64:
            sustain = value >= 0.5
            if !sustain { for n in sustained { noteOff(note: n) }; sustained.removeAll(keepingCapacity: true) }
        case 120, 123: allNotesOff(hard: cc == 120)
        default: break
        }
    }

    open func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        left.update(repeating: 0, count: frameCount)
        right.update(repeating: 0, count: frameCount)
        for v in voices where v.isActive { v.render(left: left, right: right, frameCount: frameCount) }
        postProcess(left: left, right: right, frameCount: frameCount)
    }

    /// Hook for instrument-level effects (chorus on string machines, rotary on organ...).
    open func postProcess(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {}

    open func setExtra(_ key: String, value: String) { extras[key] = value; extraDidChange(key) }
    open func extraDidChange(_ key: String) {}

    @inline(__always) public func p(_ i: Int) -> Float { parameters.all[i].value }
    @inline(__always) public func pi(_ i: Int) -> Int { Int(parameters.all[i].value.rounded()) }
}

// MARK: - Building blocks

/// ADSR envelope (exponential-ish segments).
public struct ADSR {
    public enum Stage { case idle, attack, decay, sustain, release }
    public private(set) var stage: Stage = .idle
    public private(set) var value: Float = 0
    private var attackStep: Float = 0.01, decayCoef: Float = 0.999, releaseCoef: Float = 0.999
    private var sustainLevel: Float = 0.7
    public init() {}
    public mutating func set(attack: Float, decay: Float, sustain: Float, release: Float, sampleRate: Float) {
        attackStep = 1 / max(1, attack * sampleRate)
        decayCoef = onePoleCoef(seconds: max(0.001, decay) / 4, sampleRate: sampleRate)
        releaseCoef = onePoleCoef(seconds: max(0.001, release) / 4, sampleRate: sampleRate)
        sustainLevel = sustain
    }
    public mutating func gate(_ on: Bool, retrigger: Bool = true) {
        if on { if retrigger || stage == .idle || stage == .release { stage = .attack } } else if stage != .idle { stage = .release }
    }
    public mutating func kill() { stage = .idle; value = 0 }
    public var isActive: Bool { stage != .idle }
    @inline(__always) public mutating func next() -> Float {
        switch stage {
        case .idle: return 0
        case .attack:
            value += attackStep
            if value >= 1 { value = 1; stage = .decay }
        case .decay:
            value = sustainLevel + decayCoef * (value - sustainLevel)
            if abs(value - sustainLevel) < 1e-4 { stage = .sustain }
        case .sustain:
            value = sustainLevel
            if sustainLevel <= 1e-4 { stage = .idle; value = 0 }
        case .release:
            value *= releaseCoef
            if value < 1e-5 { value = 0; stage = .idle }
        }
        return value
    }
}

/// Band-limited oscillator using PolyBLEP correction for saw and pulse.
public struct Oscillator {
    public enum Wave: Int { case saw, square, triangle, sine, noise }
    public var phase: Float = 0
    private var tri: Float = 0
    private var rng = FastRandom(seed: 0xC0FFEE)
    public init(phase: Float = 0, seed: UInt32 = 0xC0FFEE) { self.phase = phase; rng = FastRandom(seed: seed) }

    @inline(__always) static func polyBlep(_ t: Float, _ dt: Float) -> Float {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    /// `dt` = frequency / sampleRate. `pm` = phase modulation (FM) in cycles.
    @inline(__always) public mutating func next(_ wave: Wave, dt: Float, pw: Float = 0.5, pm: Float = 0) -> Float {
        var t = phase + pm
        t -= floorf(t)
        let out: Float
        switch wave {
        case .saw:
            out = 2 * t - 1 - Oscillator.polyBlep(t, dt)
        case .square:
            var s: Float = t < pw ? 1 : -1
            s += Oscillator.polyBlep(t, dt)
            var t2 = t - pw + 1; t2 -= floorf(t2)
            s -= Oscillator.polyBlep(t2, dt)
            out = s
        case .triangle:
            out = 4 * abs(t - 0.5) - 1
        case .sine:
            out = sinf(twoPi * t)
        case .noise:
            out = rng.bipolar()
        }
        phase += dt
        if phase >= 1 { phase -= 1 }
        return out
    }
}

// MARK: - Registry

public struct InstrumentDescriptor {
    public let typeID: String
    public let name: String
    public let summary: String
    public let factory: () -> Instrument
}

public final class InstrumentRegistry: @unchecked Sendable {
    public static let shared = InstrumentRegistry()
    private let lock = NSLock()
    private var descriptors: [String: InstrumentDescriptor] = [:]

    private init() {
        register(.init(typeID: "synth.subtractive", name: "Subtractive Synth", summary: "Multi-osc, unison, FM, filter, LFO") { SubtractiveSynth() })
        register(.init(typeID: "synth.bass", name: "Bass Synth", summary: "Mono bass with sub osc & drive") { SubtractiveSynth.bass() })
        register(.init(typeID: "keys", name: "Keys", summary: "Piano, electric piano, Rhodes, organ, harpsichord, strings") { KeysInstrument() })
        register(.init(typeID: "brass.trumpet", name: "Trumpet / Brass", summary: "Physically-inspired brass voice with mutes") { BrassInstrument() })
        register(.init(typeID: "drums", name: "Drum Machine", summary: "Synth & sample drum kit") { DrumMachine() })
    }

    public func register(_ d: InstrumentDescriptor) { lock.lock(); descriptors[d.typeID] = d; lock.unlock() }
    public var all: [InstrumentDescriptor] { lock.lock(); defer { lock.unlock() }; return descriptors.values.sorted { $0.name < $1.name } }
    public func make(_ typeID: String) -> Instrument? { lock.lock(); let d = descriptors[typeID]; lock.unlock(); return d?.factory() }
    public func make(from state: InstrumentState) -> Instrument? {
        guard let i = make(state.type) else { return nil }
        for (k, v) in state.extra { i.setExtra(k, value: v) }
        i.parameters.apply(state.params)
        return i
    }
}
