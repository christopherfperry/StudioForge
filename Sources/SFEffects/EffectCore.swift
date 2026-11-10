import Foundation
import SFCore

/// Every insert effect (built-in DSP or hosted Audio Unit) conforms to this protocol.
/// Processing is stereo, in place, and must be real-time safe.
public protocol AudioEffect: AnyObject {
    var typeID: String { get }
    var displayName: String { get }
    var parameters: ParameterSet { get }
    /// Processing delay introduced by the effect, used for plugin-delay compensation.
    var latencySamples: Int { get }
    /// Called off the audio thread before processing starts or when the format changes.
    func prepare(sampleRate: Double, maxFrames: Int)
    func reset()
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int)
    /// Non-numeric configuration (never called on the audio thread).
    func setExtra(_ key: String, value: String)
    var extras: [String: String] { get }
    /// Optional gain-reduction or modulation readout for meters (0 when unused).
    var meterValue: Float { get }
    /// Called on the main thread after the UI changed parameters, for work that must not run on
    /// the audio thread (e.g. re-synthesizing an impulse response).
    func parametersChangedOffline()
}

public extension AudioEffect {
    var meterValue: Float { 0 }
    func parametersChangedOffline() {}
    func state(bypassed: Bool = false, mix: Float = 1) -> EffectState {
        EffectState(type: typeID, bypassed: bypassed, mix: mix, params: parameters.snapshot(), extra: extras)
    }
}

public enum EffectCategory: String, CaseIterable, Codable {
    case eq = "EQ & Filter", dynamics = "Dynamics", drive = "Drive & Amp", modulation = "Modulation"
    case delay = "Delay", reverb = "Reverb", pitch = "Pitch & Formant", utility = "Utility", plugin = "Audio Units"
}

/// Convenience base class for built-in effects.
open class EffectBase: AudioEffect {
    public let typeID: String
    public let displayName: String
    public let parameters: ParameterSet
    public private(set) var sampleRate: Double = 48_000
    public private(set) var maxFrames: Int = 4096
    public private(set) var extras: [String: String] = [:]
    public let meter = AtomicFloat(0)
    open var latencySamples: Int { 0 }
    public var meterValue: Float { meter.value }
    public var fs: Float { Float(sampleRate) }

    public init(typeID: String, name: String, specs: [ParameterSpec]) {
        self.typeID = typeID
        self.displayName = name
        self.parameters = ParameterSet(specs)
    }

    /// Subclasses must call super.
    open func prepare(sampleRate: Double, maxFrames: Int) {
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
    }
    open func reset() {}
    open func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {}
    open func setExtra(_ key: String, value: String) {
        extras[key] = value
        extraDidChange(key)
    }
    open func extraDidChange(_ key: String) {}
    open func parametersChangedOffline() {}

    @inline(__always) public func p(_ i: Int) -> Float { parameters.all[i].value }
    @inline(__always) public func pi(_ i: Int) -> Int { Int(parameters.all[i].value.rounded()) }
}

// MARK: - Effect chain (real-time)

/// One slot of an insert chain: effect + lock-free bypass and dry/wet controls.
public final class EffectSlot {
    public let id: UUID
    public let effect: AudioEffect
    public let bypass: AtomicBool
    public let mix: AtomicFloat
    fileprivate let dryL: ScratchBuffer
    fileprivate let dryR: ScratchBuffer

    public init(id: UUID = UUID(), effect: AudioEffect, bypassed: Bool = false, mix: Float = 1, maxFrames: Int) {
        self.id = id
        self.effect = effect
        bypass = AtomicBool(bypassed)
        self.mix = AtomicFloat(mix)
        dryL = ScratchBuffer(capacity: maxFrames)
        dryR = ScratchBuffer(capacity: maxFrames)
    }
}

public final class EffectChain {
    public let slots: [EffectSlot]
    public let maxFrames: Int
    public init(slots: [EffectSlot], maxFrames: Int) { self.slots = slots; self.maxFrames = maxFrames }

    public var latencySamples: Int { slots.reduce(0) { $0 + ($1.bypass.value ? 0 : $1.effect.latencySamples) } }

    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let n = min(maxFrames, frameCount - offset)
            let l = left + offset, r = right + offset
            for slot in slots where !slot.bypass.value {
                let mix = slot.mix.value
                if mix >= 0.999 {
                    slot.effect.process(left: l, right: r, frameCount: n)
                } else if mix > 0.001 {
                    slot.dryL.data.update(from: l, count: n)
                    slot.dryR.data.update(from: r, count: n)
                    slot.effect.process(left: l, right: r, frameCount: n)
                    let dry = 1 - mix
                    for i in 0..<n {
                        l[i] = l[i] * mix + slot.dryL.data[i] * dry
                        r[i] = r[i] * mix + slot.dryR.data[i] * dry
                    }
                }
            }
            offset += n
        }
        BufferOps.sanitize(left, frameCount)
        BufferOps.sanitize(right, frameCount)
    }

    public func reset() { slots.forEach { $0.effect.reset() } }
}

// MARK: - Registry

public struct EffectDescriptor {
    public let typeID: String
    public let name: String
    public let category: EffectCategory
    public let summary: String
    public let factory: () -> AudioEffect
    public init(typeID: String, name: String, category: EffectCategory, summary: String = "", factory: @escaping () -> AudioEffect) {
        self.typeID = typeID; self.name = name; self.category = category; self.summary = summary; self.factory = factory
    }
}

/// Central registry. Built-ins are registered automatically; platform code registers the
/// Audio Unit factory (`typeID == "au"`), and you can register your own effects at launch
/// (see docs/EXTENDING.md).
public final class EffectRegistry: @unchecked Sendable {
    public static let shared = EffectRegistry()
    private let lock = NSLock()
    private var descriptors: [String: EffectDescriptor] = [:]
    /// Factory for effects whose type is resolved dynamically (e.g. AU plugins) from an EffectState.
    private var dynamicFactories: [String: (EffectState) -> AudioEffect?] = [:]

    private init() { BuiltInEffects.registerAll(into: self) }

    public func register(_ d: EffectDescriptor) { lock.lock(); descriptors[d.typeID] = d; lock.unlock() }
    public func registerDynamic(typeID: String, factory: @escaping (EffectState) -> AudioEffect?) {
        lock.lock(); dynamicFactories[typeID] = factory; lock.unlock()
    }

    public var all: [EffectDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return descriptors.values.sorted { ($0.category.rawValue, $0.name) < ($1.category.rawValue, $1.name) }
    }
    public func descriptor(_ typeID: String) -> EffectDescriptor? { lock.lock(); defer { lock.unlock() }; return descriptors[typeID] }

    public func make(_ typeID: String) -> AudioEffect? { descriptor(typeID)?.factory() }

    /// Builds and configures an effect from serialized state (non-real-time).
    public func make(from state: EffectState) -> AudioEffect? {
        lock.lock(); let dyn = dynamicFactories[state.type]; lock.unlock()
        if let dyn { return dyn(state) }
        guard let fx = make(state.type) else { return nil }
        for (k, v) in state.extra { fx.setExtra(k, value: v) }
        fx.parameters.apply(state.params)
        return fx
    }

    /// Builds a ready-to-run chain from states. Unknown effect types are skipped (logged).
    public func makeChain(_ states: [EffectState], sampleRate: Double, maxFrames: Int) -> EffectChain {
        var slots: [EffectSlot] = []
        for s in states {
            guard let fx = make(from: s) else {
                print("[StudioForge] Unknown effect type '\(s.type)' skipped")
                continue
            }
            fx.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
            slots.append(EffectSlot(id: s.id, effect: fx, bypassed: s.bypassed, mix: s.mix, maxFrames: maxFrames))
        }
        return EffectChain(slots: slots, maxFrames: maxFrames)
    }
}
