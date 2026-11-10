import Foundation
import SFCore

/// Loads factory presets (bundled JSON) and user presets (Application Support), and saves/deletes
/// user presets. Not used on the audio thread.
public final class PresetLibrary {
    public static let shared = PresetLibrary()

    public private(set) var presets: [Preset] = []
    /// Problems encountered while loading (shown in the preset browser so broken JSON is visible).
    public private(set) var loadErrors: [String] = []

    public let factoryDirectory: URL?
    public let userDirectory: URL

    public init(factoryDirectory: URL? = PresetLibrary.bundledPresetDirectory(), userDirectory: URL = AppPaths.userPresets) {
        self.factoryDirectory = factoryDirectory
        self.userDirectory = userDirectory
        reload()
    }

    /// Location of the presets shipped with the app (SwiftPM resource bundle).
    public static func bundledPresetDirectory() -> URL? {
        if let url = ResourceLocator.directory(bundle: "StudioForge_SFPresets", folder: "Presets") { return url }
        if let url = Bundle.module.url(forResource: "Presets", withExtension: nil) { return url }
        return Bundle.module.resourceURL?.appendingPathComponent("Presets")
    }

    public func reload() {
        var all: [String: Preset] = [:]
        var errors: [String] = []
        if let dir = factoryDirectory {
            for var p in Self.loadDirectory(dir, errors: &errors) { p.isFactory = true; all[p.id] = p }
        }
        // User presets override factory presets with the same id.
        for p in Self.loadDirectory(userDirectory, errors: &errors) { all[p.id] = p }
        presets = all.values.sorted { ($0.category.rawValue, $0.artistStyle, $0.name) < ($1.category.rawValue, $1.artistStyle, $1.name) }
        loadErrors = errors
    }

    static func loadDirectory(_ dir: URL, errors: inout [String]) -> [Preset] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [Preset] = []
        for f in files where f.pathExtension.lowercased() == "json" {
            do { out.append(try load(from: f)) }
            catch { errors.append("\(f.lastPathComponent): \(error.localizedDescription)") }
        }
        return out
    }

    public static func load(from url: URL) throws -> Preset {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Preset.self, from: data)
    }

    public static func encode(_ preset: Preset) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(preset)
    }

    /// Saves a preset into the user folder. Factory presets are never overwritten in place;
    /// saving one stores a user copy with the same id which then takes precedence.
    @discardableResult
    public func save(_ preset: Preset) throws -> URL {
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        var p = preset
        if p.id.isEmpty { p.id = Preset.slug(p.name) }
        let url = userDirectory.appendingPathComponent("\(Preset.slug(p.id)).json")
        try Self.encode(p).write(to: url, options: .atomic)
        reload()
        return url
    }

    /// Duplicates a preset under a new name and saves it as a user preset.
    @discardableResult
    public func duplicate(_ preset: Preset, newName: String) throws -> Preset {
        var p = preset
        p.name = newName
        p.id = Preset.slug(newName) + "-" + String(UUID().uuidString.prefix(6)).lowercased()
        p.isFactory = false
        try save(p)
        return p
    }

    /// Deletes a user preset. Returns false for factory presets (they cannot be deleted).
    @discardableResult
    public func delete(_ preset: Preset) throws -> Bool {
        let url = userDirectory.appendingPathComponent("\(Preset.slug(preset.id)).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        reload()
        return true
    }

    public func preset(id: String) -> Preset? { presets.first { $0.id == id } }

    public func presets(in category: PresetCategory?) -> [Preset] {
        guard let c = category else { return presets }
        return presets.filter { $0.category == c }
    }

    /// Free-text search across name, artist style, tags and description.
    public func search(_ text: String, category: PresetCategory? = nil) -> [Preset] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        return presets(in: category).filter { p in
            q.isEmpty || p.name.lowercased().contains(q) || p.artistStyle.lowercased().contains(q)
                || p.description.lowercased().contains(q) || p.tags.contains { $0.lowercased().contains(q) }
        }
    }

    /// All artist styles present in the library (for the Tone Picker).
    public var artistStyles: [String] {
        Array(Set(presets.map(\.artistStyle).filter { !$0.isEmpty })).sorted()
    }
}

/// "Choose an artist + instrument, get a sound." Picks the best matching preset.
public struct TonePicker {
    public let library: PresetLibrary
    public init(library: PresetLibrary = .shared) { self.library = library }

    public func artists(for category: PresetCategory? = nil) -> [String] {
        Array(Set(library.presets(in: category).map(\.artistStyle).filter { !$0.isEmpty })).sorted()
    }

    /// Presets for an artist style and category, best match first (exact artist match, then
    /// presets whose tags mention the artist).
    public func candidates(artist: String, category: PresetCategory) -> [Preset] {
        let a = artist.lowercased()
        let inCat = library.presets(in: category)
        let exact = inCat.filter { $0.artistStyle.lowercased() == a }
        let tagged = inCat.filter { p in p.artistStyle.lowercased() != a && p.tags.contains { $0.lowercased() == a } }
        return exact + tagged
    }

    public func pick(artist: String, category: PresetCategory) -> Preset? {
        candidates(artist: artist, category: category).first ?? library.presets(in: category).first
    }
}
