import Foundation

/// Serializable state of one effect slot (used by projects and presets).
public struct EffectState: Codable, Hashable, Identifiable {
    public var id: UUID
    public var type: String
    public var bypassed: Bool
    public var mix: Float
    public var params: [String: Float]
    /// Non-numeric configuration: IR file path, AU component description, AU state blob (base64)...
    public var extra: [String: String]

    public init(id: UUID = UUID(), type: String, bypassed: Bool = false, mix: Float = 1,
                params: [String: Float] = [:], extra: [String: String] = [:]) {
        self.id = id; self.type = type; self.bypassed = bypassed; self.mix = mix
        self.params = params; self.extra = extra
    }

    enum CodingKeys: String, CodingKey { case id, type, bypassed, mix, params, extra }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decode(String.self, forKey: .type)
        bypassed = try c.decodeIfPresent(Bool.self, forKey: .bypassed) ?? false
        mix = try c.decodeIfPresent(Float.self, forKey: .mix) ?? 1
        params = try c.decodeIfPresent([String: Float].self, forKey: .params) ?? [:]
        extra = try c.decodeIfPresent([String: String].self, forKey: .extra) ?? [:]
    }
}

/// Serializable state of an instrument.
public struct InstrumentState: Codable, Hashable {
    public var type: String
    public var params: [String: Float]
    public var extra: [String: String]
    public init(type: String, params: [String: Float] = [:], extra: [String: String] = [:]) {
        self.type = type; self.params = params; self.extra = extra
    }
    enum CodingKeys: String, CodingKey { case type, params, extra }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        params = try c.decodeIfPresent([String: Float].self, forKey: .params) ?? [:]
        extra = try c.decodeIfPresent([String: String].self, forKey: .extra) ?? [:]
    }
}

/// A note in beats (quarter notes).
public struct MIDINote: Codable, Hashable, Identifiable {
    public var id: UUID
    public var pitch: Int
    public var velocity: Int
    public var startBeat: Double
    public var durationBeats: Double
    public init(id: UUID = UUID(), pitch: Int, velocity: Int, startBeat: Double, durationBeats: Double) {
        self.id = id; self.pitch = pitch; self.velocity = velocity
        self.startBeat = startBeat; self.durationBeats = durationBeats
    }
}

public struct TimeSignature: Codable, Hashable, CustomStringConvertible {
    public var numerator: Int
    public var denominator: Int
    public init(_ n: Int = 4, _ d: Int = 4) { numerator = n; denominator = d }
    /// Bar length in quarter-note beats.
    public var quarterNotesPerBar: Double { Double(numerator) * 4 / Double(denominator) }
    public var description: String { "\(numerator)/\(denominator)" }
}

/// Live MIDI event passed from CoreMIDI / UI keyboard to the audio thread.
public struct LiveMIDIEvent {
    public enum Kind: UInt8 { case noteOn, noteOff, pitchBend, controlChange, allNotesOff }
    public var kind: Kind
    public var data1: UInt8
    public var data2: UInt8
    public var value: Float
    public init(kind: Kind, data1: UInt8 = 0, data2: UInt8 = 0, value: Float = 0) {
        self.kind = kind; self.data1 = data1; self.data2 = data2; self.value = value
    }
    public static let empty = LiveMIDIEvent(kind: .allNotesOff)
}

/// Decoded multi-channel audio held in memory (non-real-time container).
public struct AudioData {
    public var channels: [[Float]]
    public var sampleRate: Double
    public init(channels: [[Float]], sampleRate: Double) { self.channels = channels; self.sampleRate = sampleRate }
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var channelCount: Int { channels.count }
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
    public var mono: [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        var m = [Float](repeating: 0, count: first.count)
        let g = 1 / Float(channels.count)
        for ch in channels { for i in 0..<min(m.count, ch.count) { m[i] += ch[i] * g } }
        return m
    }
    /// Returns a stereo version (duplicating mono).
    public var stereo: AudioData {
        if channels.count >= 2 { return AudioData(channels: Array(channels.prefix(2)), sampleRate: sampleRate) }
        let c = channels.first ?? []
        return AudioData(channels: [c, c], sampleRate: sampleRate)
    }
    public var peak: Float { channels.map { $0.reduce(0) { max($0, abs($1)) } }.max() ?? 0 }
}

/// Pluggable decoder so platform code (AVFoundation) can register support for MP3/AAC/FLAC/...
/// while core code keeps a portable WAV/AIFF reader.
public enum AudioDecoding {
    public typealias Decoder = (URL) throws -> AudioData
    private static let lock = NSLock()
    private static var decoders: [Decoder] = []

    public static func register(_ d: @escaping Decoder) {
        lock.lock(); decoders.insert(d, at: 0); lock.unlock()
    }
    public static func decode(_ url: URL) throws -> AudioData {
        lock.lock(); let ds = decoders; lock.unlock()
        var lastError: Error?
        for d in ds {
            do { return try d(url) } catch { lastError = error }
        }
        do { return try AudioFileIO.read(url) } catch { throw lastError ?? error }
    }
}

public enum StudioForgeError: LocalizedError {
    case unsupportedFormat(String)
    case io(String)
    case invalid(String)
    case missingModel(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let s): return "Unsupported format: \(s)"
        case .io(let s): return "File error: \(s)"
        case .invalid(let s): return s
        case .missingModel(let s): return "Model not installed: \(s)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Standard locations (Application Support on macOS, ~/.studioforge elsewhere).
public enum AppPaths {
    public static var support: URL {
        let fm = FileManager.default
        #if os(macOS)
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("StudioForge", isDirectory: true)
        #else
        let url = fm.homeDirectoryForCurrentUser.appendingPathComponent(".studioforge", isDirectory: true)
        #endif
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static func sub(_ name: String) -> URL {
        let u = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// User-visible library root: ~/Music/StudioForge (created by first-run setup / installer).
    public static var musicRoot: URL {
        let fm = FileManager.default
        let music = fm.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        let url = music.appendingPathComponent("StudioForge", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static func library(_ path: String) -> URL {
        let u = musicRoot.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// Folders created on first launch (relative to `musicRoot`).
    public static let libraryFolders = ["Projects", "Recordings", "Exports", "Presets/User", "Presets/Factory",
                                        "ImpulseResponses", "Models", "Samples"]
    public static var projects: URL { library("Projects") }
    public static var recordings: URL { library("Recordings") }
    public static var exports: URL { library("Exports") }
    public static var samples: URL { library("Samples") }
    public static var userPresets: URL { library("Presets/User") }
    public static var factoryPresetsCopy: URL { library("Presets/Factory") }
    public static var userBeatStyles: URL { sub("BeatStyles") }
    public static var models: URL { library("Models") }
    public static var impulseResponses: URL { library("ImpulseResponses") }
    public static var templates: URL { sub("Templates") }
    public static var defaultProjectsFolder: URL { projects }
}

/// Finds SwiftPM resource bundles inside a distributed .app. SwiftPM's generated `Bundle.module`
/// only looks next to the .app (StudioForge.app/X.bundle, which breaks code signing) and at the
/// absolute build path, and calls fatalError otherwise. build.sh copies the bundles into
/// Contents/Resources, so look there first; callers fall back to `Bundle.module` for
/// `swift run` / `swift test`.
public enum ResourceLocator {
    public static func directory(bundle name: String, folder: String) -> URL? {
        let fm = FileManager.default
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }
        roots.append(Bundle.main.bundleURL)
        if let e = Bundle.main.executableURL?.deletingLastPathComponent() { roots.append(e) }
        for root in roots {
            for ext in ["bundle", "resources"] {
                let b = root.appendingPathComponent("\(name).\(ext)")
                for candidate in [b.appendingPathComponent(folder), b.appendingPathComponent("Contents/Resources/\(folder)")]
                where fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
