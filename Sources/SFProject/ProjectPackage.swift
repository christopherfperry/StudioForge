import Foundation
import SFCore

/// On-disk project format: a folder package `Name.sforge/`
///
///     project.json      – manifest (the `Project` value, pretty-printed JSON)
///     Audio/            – recorded and imported audio (WAV/AIFF/…)
///     Peaks/            – waveform overview cache (safe to delete)
///     Bounces/          – default export location
///     autosave.json     – latest autosave (removed on explicit save)
public enum ProjectPackage {
    public static let fileExtension = "sfproj"
    /// Extensions from earlier versions that can still be opened.
    public static let readableExtensions = ["sfproj", "sforge"]
    public static let manifestName = "project.json"
    public static let autosaveName = "autosave.json"
    public static let audioFolder = "Audio"
    public static let peaksFolder = "Peaks"
    public static let bouncesFolder = "Bounces"

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Creates the package folder structure.
    public static func create(at url: URL) throws {
        let fm = FileManager.default
        for sub in ["", audioFolder, peaksFolder, bouncesFolder] {
            try fm.createDirectory(at: sub.isEmpty ? url : url.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    /// Saves the manifest atomically and removes any stale autosave.
    public static func save(_ project: Project, to url: URL) throws {
        try create(at: url)
        var p = project
        p.modifiedAt = Date()
        let data = try encoder().encode(p)
        try data.write(to: url.appendingPathComponent(manifestName), options: .atomic)
        try? FileManager.default.removeItem(at: url.appendingPathComponent(autosaveName))
    }

    public static func load(from url: URL) throws -> Project {
        let manifest = url.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw StudioForgeError.io("\(url.lastPathComponent) is not a Fitzrovia Records DAW project (missing project.json).")
        }
        let p = try decoder().decode(Project.self, from: Data(contentsOf: manifest))
        if p.version > Project.currentVersion {
            throw StudioForgeError.invalid("This project was saved by a newer version of Fitzrovia Records DAW.")
        }
        return p
    }

    public static func writeAutosave(_ project: Project, to url: URL) throws {
        try create(at: url)
        try encoder().encode(project).write(to: url.appendingPathComponent(autosaveName), options: .atomic)
    }

    /// Returns the autosaved project if it is newer than the saved manifest.
    public static func newerAutosave(in url: URL) -> Project? {
        let fm = FileManager.default
        let a = url.appendingPathComponent(autosaveName), m = url.appendingPathComponent(manifestName)
        guard let aDate = (try? fm.attributesOfItem(atPath: a.path))?[.modificationDate] as? Date else { return nil }
        let mDate = (try? fm.attributesOfItem(atPath: m.path))?[.modificationDate] as? Date ?? .distantPast
        guard aDate > mDate, let data = try? Data(contentsOf: a) else { return nil }
        return try? decoder().decode(Project.self, from: data)
    }

    /// Resolves a clip file path (relative to the package, or absolute).
    public static func resolve(_ file: String, in package: URL?) -> URL {
        if file.hasPrefix("/") { return URL(fileURLWithPath: file) }
        guard let pkg = package else { return URL(fileURLWithPath: file) }
        return pkg.appendingPathComponent(file)
    }

    /// Copies an external audio file into the package's Audio folder (unique name).
    /// Returns the package-relative path.
    public static func importAudio(_ source: URL, into package: URL) throws -> String {
        let fm = FileManager.default
        let dir = package.appendingPathComponent(audioFolder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = uniqueURL(in: dir, baseName: source.deletingPathExtension().lastPathComponent, ext: source.pathExtension)
        try fm.copyItem(at: source, to: dest)
        return "\(audioFolder)/\(dest.lastPathComponent)"
    }

    /// A non-existing file URL in `dir` like "Base.wav", "Base 2.wav", ...
    public static func uniqueURL(in dir: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        let clean = baseName.replacingOccurrences(of: "/", with: "-")
        var url = dir.appendingPathComponent(clean).appendingPathExtension(ext)
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(clean) \(i)").appendingPathExtension(ext)
            i += 1
        }
        return url
    }

    /// Audio files in the package not referenced by any clip (for "Clean Up Project").
    public static func unusedAudio(in package: URL, project: Project) -> [URL] {
        let used = Set(project.tracks.flatMap { $0.audioClips.map { resolve($0.file, in: package).standardizedFileURL.path } })
        let dir = package.appendingPathComponent(audioFolder)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { !used.contains($0.standardizedFileURL.path) }
    }
}

/// Recently opened projects (stored in UserDefaults).
public final class RecentProjects {
    public static let shared = RecentProjects()
    private let key = "SFRecentProjects"
    private let defaults: UserDefaults
    public var limit = 12

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var urls: [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func add(_ url: URL) {
        var list = (defaults.stringArray(forKey: key) ?? []).filter { $0 != url.path }
        list.insert(url.path, at: 0)
        defaults.set(Array(list.prefix(limit)), forKey: key)
    }

    public func remove(_ url: URL) {
        defaults.set((defaults.stringArray(forKey: key) ?? []).filter { $0 != url.path }, forKey: key)
    }

    public func clear() { defaults.removeObject(forKey: key) }
}

/// Periodically autosaves a project. The owner supplies closures for the current project, the
/// package URL (nil = untitled → saved in Application Support/Autosave) and whether it is dirty.
public final class AutosaveController {
    public var interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "studioforge.autosave", qos: .utility)
    public var currentProject: () -> Project?
    public var packageURL: () -> URL?
    public var isDirty: () -> Bool
    public var didAutosave: ((URL) -> Void)?

    public init(interval: TimeInterval = 60, currentProject: @escaping () -> Project?,
                packageURL: @escaping () -> URL?, isDirty: @escaping () -> Bool) {
        self.interval = interval; self.currentProject = currentProject; self.packageURL = packageURL; self.isDirty = isDirty
    }

    public func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// Untitled projects are autosaved here.
    public static var untitledFolder: URL { AppPaths.sub("Autosave") }

    func tick() {
        // Fetch state on the main thread (the document lives there), write on the background queue.
        var project: Project?
        var pkg: URL?
        var dirty = false
        DispatchQueue.main.sync {
            dirty = self.isDirty()
            if dirty { project = self.currentProject(); pkg = self.packageURL() }
        }
        guard dirty, let p = project else { return }
        let url = pkg ?? Self.untitledFolder.appendingPathComponent("\(p.id.uuidString).\(ProjectPackage.fileExtension)")
        do {
            try ProjectPackage.writeAutosave(p, to: url)
            DispatchQueue.main.async { self.didAutosave?(url) }
        } catch {
            NSLog("Fitzrovia Records DAW autosave failed: \(error.localizedDescription)")
        }
    }

    deinit { stop() }
}
