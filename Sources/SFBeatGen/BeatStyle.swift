import Foundation
import SFCore

/// A drum-pattern style template, stored as human-editable JSON (see Resources/BeatStyles).
///
/// Lanes are written as step strings, one character per step (16th notes in 4/4, so 16 chars
/// per bar; a 7/8 bar has 14). A lane string may span several bars — it loops.
///
///   `X` accent (velocity ~118)    `x` normal hit (~96)    `o` ghost note (~50)
///   `?` optional hit — plays with probability = complexity    `.` or `-` rest
///   `|` and spaces are ignored (use them to make bars readable)
public struct BeatStyle: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var genre: String
    public var artistStyle: String
    public var description: String
    public var timeSignature: TimeSignature
    /// Steps per bar (16 for 4/4 sixteenths, 14 for 7/8 sixteenths, 12 for 6/8 or 12/8 eighths...).
    public var stepsPerBar: Int
    public var tempoRange: [Double]
    public var defaultTempo: Double
    public var defaultSwing: Double
    /// Main groove: laneKey -> step string.
    public var lanes: [String: String]
    /// Extra lanes layered in when complexity > 0.5 (ghost notes, extra hats...).
    public var complexLanes: [String: String]
    /// Fill bars (one is chosen at random). Each replaces the groove for one bar.
    public var fills: [[String: String]]
    /// Lanes that get a crash on bar 1 of each phrase (usually ["crash"]).
    public var phraseAccent: [String]
    /// Suggested kit preset id.
    public var kitPreset: String?

    public init(id: String, name: String, genre: String = "", artistStyle: String = "", description: String = "",
                timeSignature: TimeSignature = TimeSignature(4, 4), stepsPerBar: Int = 16,
                tempoRange: [Double] = [80, 140], defaultTempo: Double = 110, defaultSwing: Double = 0,
                lanes: [String: String], complexLanes: [String: String] = [:], fills: [[String: String]] = [],
                phraseAccent: [String] = ["crash"], kitPreset: String? = nil) {
        self.id = id; self.name = name; self.genre = genre; self.artistStyle = artistStyle
        self.description = description; self.timeSignature = timeSignature; self.stepsPerBar = stepsPerBar
        self.tempoRange = tempoRange; self.defaultTempo = defaultTempo; self.defaultSwing = defaultSwing
        self.lanes = lanes; self.complexLanes = complexLanes; self.fills = fills
        self.phraseAccent = phraseAccent; self.kitPreset = kitPreset
    }

    enum CodingKeys: String, CodingKey {
        case id, name, genre, artistStyle, description, timeSignature, stepsPerBar, tempoRange, defaultTempo
        case defaultSwing, lanes, complexLanes, fills, phraseAccent, kitPreset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        artistStyle = try c.decodeIfPresent(String.self, forKey: .artistStyle) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        timeSignature = try c.decodeIfPresent(TimeSignature.self, forKey: .timeSignature) ?? TimeSignature(4, 4)
        stepsPerBar = try c.decodeIfPresent(Int.self, forKey: .stepsPerBar) ?? 16
        tempoRange = try c.decodeIfPresent([Double].self, forKey: .tempoRange) ?? [80, 140]
        defaultTempo = try c.decodeIfPresent(Double.self, forKey: .defaultTempo) ?? 110
        defaultSwing = try c.decodeIfPresent(Double.self, forKey: .defaultSwing) ?? 0
        lanes = try c.decode([String: String].self, forKey: .lanes)
        complexLanes = try c.decodeIfPresent([String: String].self, forKey: .complexLanes) ?? [:]
        fills = try c.decodeIfPresent([[String: String]].self, forKey: .fills) ?? []
        phraseAccent = try c.decodeIfPresent([String].self, forKey: .phraseAccent) ?? ["crash"]
        kitPreset = try c.decodeIfPresent(String.self, forKey: .kitPreset)
    }

    public var minTempo: Double { tempoRange.first ?? 60 }
    public var maxTempo: Double { tempoRange.count > 1 ? tempoRange[1] : 200 }
    /// Length of one step in quarter-note beats.
    public var stepBeats: Double { timeSignature.quarterNotesPerBar / Double(max(1, stepsPerBar)) }
}

/// One parsed step of a lane string.
public enum StepKind: Equatable {
    case rest, ghost, normal, accent, optional

    public static func parse(_ s: String) -> [StepKind] {
        var out: [StepKind] = []
        for ch in s {
            switch ch {
            case "X": out.append(.accent)
            case "x": out.append(.normal)
            case "o", "g": out.append(.ghost)
            case "?": out.append(.optional)
            case ".", "-", "_": out.append(.rest)
            default: continue // '|', spaces, anything else: visual separators
            }
        }
        return out
    }
}

/// Lane key -> General MIDI drum note. Mirrors `DrumPad` in SFInstruments (kept here so the beat
/// generator has no dependency on the synth engine).
public enum DrumMap {
    public static let notes: [String: Int] = [
        "kick": 36, "rim": 37, "snare": 38, "clap": 39, "tomLow": 41, "hatClosed": 42, "hatPedal": 44,
        "tomMid": 45, "hatOpen": 46, "tomHigh": 48, "crash": 49, "ride": 51, "china": 52,
        "tambourine": 54, "cowbell": 56, "metal": 75,
    ]
    public static func note(for lane: String) -> Int? { notes[lane] }
    public static func lane(for note: Int) -> String? { notes.first { $0.value == note }?.key }
}

/// Loads bundled + user beat styles.
public final class BeatStyleLibrary {
    public static let shared = BeatStyleLibrary()
    public private(set) var styles: [BeatStyle] = []
    public private(set) var loadErrors: [String] = []
    public let factoryDirectory: URL?
    public let userDirectory: URL

    public init(factoryDirectory: URL? = BeatStyleLibrary.bundledDirectory(), userDirectory: URL = AppPaths.userBeatStyles) {
        self.factoryDirectory = factoryDirectory
        self.userDirectory = userDirectory
        reload()
    }

    public static func bundledDirectory() -> URL? {
        ResourceLocator.directory(bundle: "StudioForge_SFBeatGen", folder: "BeatStyles")
            ?? Bundle.module.url(forResource: "BeatStyles", withExtension: nil)
            ?? Bundle.module.resourceURL?.appendingPathComponent("BeatStyles")
    }

    public func reload() {
        var map: [String: BeatStyle] = [:]
        var errs: [String] = []
        for dir in [factoryDirectory, userDirectory].compactMap({ $0 }) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension.lowercased() == "json" {
                do { let s = try JSONDecoder().decode(BeatStyle.self, from: Data(contentsOf: f)); map[s.id] = s }
                catch { errs.append("\(f.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        styles = map.values.sorted { ($0.genre, $0.name) < ($1.genre, $1.name) }
        loadErrors = errs
    }

    public func style(id: String) -> BeatStyle? { styles.first { $0.id == id } }

    @discardableResult
    public func save(_ style: BeatStyle) throws -> URL {
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = userDirectory.appendingPathComponent("\(style.id).json")
        try enc.encode(style).write(to: url, options: .atomic)
        reload()
        return url
    }
}
