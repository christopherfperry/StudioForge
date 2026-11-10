import Foundation
import SFCore

/// Instrument category used by the preset browser and Tone Picker.
public enum PresetCategory: String, Codable, CaseIterable, Identifiable {
    case vocal = "Vocal", keys = "Keys", bass = "Bass", guitar = "Guitar", drums = "Drums", synth = "Synth", other = "Other"
    public var id: String { rawValue }

    /// Tolerant decoding: unknown categories fall back to `.other` instead of failing the whole file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PresetCategory.allCases.first { $0.rawValue.lowercased() == raw.lowercased() } ?? .other
    }
}

/// A tone / sound preset. Stored as a single human-editable JSON file.
///
/// A preset is a list of effect states (an insert chain) plus, optionally, an instrument state
/// and a suggested beat style / tempo. Unknown parameter ids are ignored on load, missing ones use
/// the effect's defaults — so presets stay valid when effects evolve.
public struct Preset: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var category: PresetCategory
    public var artistStyle: String
    public var tags: [String]
    public var description: String
    public var effects: [EffectState]
    public var instrument: InstrumentState?
    public var beatStyle: String?
    public var tempo: Double?
    /// True for presets shipped inside the app bundle (read-only; saving creates a user copy).
    public var isFactory: Bool = false

    public init(id: String = UUID().uuidString, name: String, category: PresetCategory, artistStyle: String = "",
                tags: [String] = [], description: String = "", effects: [EffectState] = [],
                instrument: InstrumentState? = nil, beatStyle: String? = nil, tempo: Double? = nil) {
        self.id = id; self.name = name; self.category = category; self.artistStyle = artistStyle
        self.tags = tags; self.description = description; self.effects = effects
        self.instrument = instrument; self.beatStyle = beatStyle; self.tempo = tempo
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, artistStyle, tags, description, effects, instrument, beatStyle, tempo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Preset.slug(name)
        category = try c.decodeIfPresent(PresetCategory.self, forKey: .category) ?? .other
        artistStyle = try c.decodeIfPresent(String.self, forKey: .artistStyle) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        effects = try c.decodeIfPresent([EffectState].self, forKey: .effects) ?? []
        instrument = try c.decodeIfPresent(InstrumentState.self, forKey: .instrument)
        beatStyle = try c.decodeIfPresent(String.self, forKey: .beatStyle)
        tempo = try c.decodeIfPresent(Double.self, forKey: .tempo)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(category.rawValue, forKey: .category)
        try c.encode(artistStyle, forKey: .artistStyle); try c.encode(tags, forKey: .tags)
        try c.encode(description, forKey: .description); try c.encode(effects, forKey: .effects)
        try c.encodeIfPresent(instrument, forKey: .instrument)
        try c.encodeIfPresent(beatStyle, forKey: .beatStyle); try c.encodeIfPresent(tempo, forKey: .tempo)
    }

    /// File-system friendly identifier derived from a name.
    public static func slug(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var out = ""
        var lastDash = false
        for ch in s.lowercased() {
            if allowed.contains(ch) { out.append(ch); lastDash = false }
            else if !lastDash && !out.isEmpty { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "preset" : out
    }
}
