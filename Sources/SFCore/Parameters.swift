import Foundation

public enum ParameterUnit: String, Codable {
    case generic, decibels, hertz, milliseconds, seconds, percent, ratio, semitones, cents, choice, toggle, bpm
}

/// Static description of a parameter (shared by built-in effects, instruments and the generic UI).
public struct ParameterSpec: Codable, Hashable {
    public var id: String
    public var name: String
    public var min: Float
    public var max: Float
    public var defaultValue: Float
    public var unit: ParameterUnit
    public var choices: [String]?
    public var logarithmic: Bool

    public init(_ id: String, _ name: String, min: Float, max: Float, default def: Float,
                unit: ParameterUnit = .generic, choices: [String]? = nil, log: Bool = false) {
        self.id = id; self.name = name; self.min = min; self.max = max
        self.defaultValue = def; self.unit = unit; self.choices = choices; self.logarithmic = log
    }

    public static func choice(_ id: String, _ name: String, _ options: [String], default def: Int = 0) -> ParameterSpec {
        ParameterSpec(id, name, min: 0, max: Float(Swift.max(0, options.count - 1)), default: Float(def), unit: .choice, choices: options)
    }
    public static func toggle(_ id: String, _ name: String, default def: Bool = false) -> ParameterSpec {
        ParameterSpec(id, name, min: 0, max: 1, default: def ? 1 : 0, unit: .toggle)
    }

    public func clamp(_ v: Float) -> Float {
        let c = Swift.min(Swift.max(v, min), max)
        return (unit == .choice || unit == .toggle) ? c.rounded() : c
    }

    /// Maps a 0...1 control position to a value (log-aware) and back — used by knobs/sliders.
    public func value(fromNormalized t: Float) -> Float {
        let t = Swift.min(Swift.max(t, 0), 1)
        if logarithmic && min > 0 { return clamp(min * powf(max / min, t)) }
        return clamp(min + (max - min) * t)
    }
    public func normalized(_ v: Float) -> Float {
        if max <= min { return 0 }
        if logarithmic && min > 0 { return logf(Swift.max(v, min) / min) / logf(max / min) }
        return (v - min) / (max - min)
    }

    public func display(_ v: Float) -> String {
        switch unit {
        case .choice: let i = Int(v.rounded()); return choices.flatMap { i >= 0 && i < $0.count ? $0[i] : nil } ?? "\(i)"
        case .toggle: return v >= 0.5 ? "On" : "Off"
        case .decibels: return String(format: "%.1f dB", v)
        case .hertz: return v >= 1000 ? String(format: "%.2f kHz", v / 1000) : String(format: "%.0f Hz", v)
        case .milliseconds: return String(format: "%.1f ms", v)
        case .seconds: return String(format: "%.2f s", v)
        case .percent: return String(format: "%.0f%%", v * 100)
        case .ratio: return String(format: "%.1f:1", v)
        case .semitones: return String(format: "%+.1f st", v)
        case .cents: return String(format: "%+.0f ct", v)
        case .bpm: return String(format: "%.1f BPM", v)
        case .generic: return String(format: "%.2f", v)
        }
    }
}

/// A live parameter: UI writes, audio thread reads (lock-free).
public final class Parameter: @unchecked Sendable {
    public let spec: ParameterSpec
    private let storage: AtomicFloat
    public init(spec: ParameterSpec) {
        self.spec = spec
        storage = AtomicFloat(spec.defaultValue)
    }
    @inline(__always) public var value: Float {
        get { storage.value }
        set { storage.value = spec.clamp(newValue) }
    }
}

/// Ordered collection of parameters with lookup by id.
public final class ParameterSet: @unchecked Sendable {
    public let all: [Parameter]
    private let index: [String: Int]

    public init(_ specs: [ParameterSpec]) {
        all = specs.map { Parameter(spec: $0) }
        var idx: [String: Int] = [:]
        for (i, s) in specs.enumerated() { idx[s.id] = i }
        index = idx
    }
    public var specs: [ParameterSpec] { all.map(\.spec) }
    @inline(__always) public subscript(i: Int) -> Float { all[i].value }
    public subscript(id: String) -> Parameter? { index[id].map { all[$0] } }
    public func contains(_ id: String) -> Bool { index[id] != nil }

    public func snapshot() -> [String: Float] {
        var d: [String: Float] = [:]
        for p in all { d[p.spec.id] = p.value }
        return d
    }
    /// Applies values; unknown keys are ignored (forward compatible presets).
    public func apply(_ values: [String: Float]) {
        for (k, v) in values { self[k]?.value = v }
    }
    public func resetToDefaults() { for p in all { p.value = p.spec.defaultValue } }
}
