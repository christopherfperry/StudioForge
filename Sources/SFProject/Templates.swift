import Foundation
import SFCore

/// One-click "New Song" templates. Tracks reference factory presets by id (`presetID`); the
/// preset library fills in the effect chain / instrument when the template is instantiated
/// (see `PresetLibrary.applyReferencedPresets`), so templates stay in sync with preset edits.
/// User templates are plain project JSON files stored in Application Support/Templates.
public struct ProjectTemplate: Identifiable, Hashable {
    public var id: String
    public var name: String
    public var summary: String
    public var symbol: String          // SF Symbol name for the UI
    public var tempo: Double
    public var timeSignature: TimeSignature
    public var tracks: [Track]
    /// Beat style id the UI uses to pre-generate a pattern for drum tracks (optional).
    public var beatStyle: String?

    public func makeProject(name: String? = nil, sampleRate: Double = 48_000) -> Project {
        var p = Project(name: name ?? "Untitled \(self.name)", tempo: tempo, timeSignature: timeSignature,
                        sampleRate: sampleRate, tracks: tracks.map { var t = $0; t.id = UUID(); return t })
        p.metronome.enabled = beatStyle == nil
        p.loop = TimeRegion(enabled: false, start: 0, end: p.secondsPerBar * 4)
        return p
    }
}

/// What the user fills in on the New Project sheet.
public struct NewProjectSettings: Equatable {
    public var name: String
    public var tempo: Double
    public var timeSignature: TimeSignature
    public init(name: String = "Untitled", tempo: Double = 120, timeSignature: TimeSignature = TimeSignature(4, 4)) {
        self.name = name; self.tempo = tempo; self.timeSignature = timeSignature
    }
    /// Common time signatures offered in the UI.
    public static let timeSignatures: [TimeSignature] = [TimeSignature(4, 4), TimeSignature(3, 4), TimeSignature(6, 8),
                                                         TimeSignature(2, 4), TimeSignature(5, 4), TimeSignature(7, 8),
                                                         TimeSignature(12, 8)]
    /// Name trimmed and safe as a file name ("Untitled" when empty).
    public var cleanName: String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let t = s.hasPrefix(".") ? String(s.drop(while: { $0 == "." })) : s
        return t.isEmpty ? "Untitled" : String(t.prefix(120))
    }
    public var clampedTempo: Double { min(300, max(30, tempo.isFinite ? tempo : 120)) }
}

extension ProjectTemplate {
    /// A project from this template with the user's name, tempo and time signature.
    public func makeProject(settings s: NewProjectSettings, sampleRate: Double = 48_000) -> Project {
        var p = makeProject(name: s.cleanName, sampleRate: sampleRate)
        p.tempo = s.clampedTempo
        p.timeSignature = s.timeSignature
        p.loop = TimeRegion(enabled: false, start: 0, end: p.secondsPerBar * 4)
        return p
    }
}

public enum ProjectTemplates {
    static func track(_ name: String, _ kind: TrackKind, color: Int, preset: String?, instrument: String? = nil,
                      input: InputSelection = InputSelection(), arm: Bool = false) -> Track {
        var t = Track(name: name, kind: kind, colorIndex: color,
                      instrument: instrument.map { InstrumentState(type: $0) })
        t.presetID = preset
        t.input = input
        t.arm = arm
        return t
    }

    public static let empty = ProjectTemplate(
        id: "empty", name: "Empty", summary: "A blank project with one audio track.", symbol: "doc",
        tempo: 120, timeSignature: TimeSignature(4, 4),
        tracks: [track("Audio 1", .audio, color: 0, preset: nil)])

    public static let vocals = ProjectTemplate(
        id: "vocals", name: "Vocals", summary: "Lead vocal + double + backing track, clean recording on.",
        symbol: "mic", tempo: 100, timeSignature: TimeSignature(4, 4),
        tracks: [
            track("Lead Vocal", .audio, color: 1, preset: "clean-vocal-starter", arm: true),
            track("Double", .audio, color: 1, preset: "clean-vocal-starter"),
            track("Backing Track", .audio, color: 6, preset: nil),
        ])

    public static let guitar = ProjectTemplate(
        id: "guitar", name: "Guitar", summary: "DI guitar through amp & cab (records clean DI), plus bass.",
        symbol: "guitars", tempo: 110, timeSignature: TimeSignature(4, 4),
        tracks: [
            track("Guitar L", .audio, color: 2, preset: "clean-guitar-starter", arm: true),
            track("Guitar R", .audio, color: 2, preset: "clean-guitar-starter"),
            track("Bass DI", .audio, color: 3, preset: "bass-di-starter", input: InputSelection(firstChannel: 1)),
        ])

    public static let band = ProjectTemplate(
        id: "band", name: "Band", summary: "Drums, bass, two guitars, keys and vocals.",
        symbol: "music.mic", tempo: 120, timeSignature: TimeSignature(4, 4),
        tracks: [
            track("Drums", .drums, color: 4, preset: "drum-machine-starter", instrument: "drums"),
            track("Bass", .audio, color: 3, preset: "bass-di-starter"),
            track("Guitar 1", .audio, color: 2, preset: "clean-guitar-starter"),
            track("Guitar 2", .audio, color: 2, preset: "clean-guitar-starter", input: InputSelection(firstChannel: 1)),
            track("Keys", .instrument, color: 5, preset: "piano-starter", instrument: "keys"),
            track("Vocal", .audio, color: 1, preset: "clean-vocal-starter"),
        ], beatStyle: "alt-rock")

    public static let beatSynth = ProjectTemplate(
        id: "beat-synth", name: "Beat + Synth", summary: "Drum machine with a generated beat, bass synth and lead synth.",
        symbol: "pianokeys", tempo: 92, timeSignature: TimeSignature(4, 4),
        tracks: [
            track("Beat", .drums, color: 4, preset: "closer-kit-dry-heavy-kick", instrument: "drums"),
            track("Bass Synth", .instrument, color: 3, preset: "bass-synth-starter", instrument: "synth.bass"),
            track("Lead Synth", .instrument, color: 5, preset: "synth-starter", instrument: "synth.subtractive"),
        ], beatStyle: "nin-closer")

    public static let builtIn: [ProjectTemplate] = [vocals, guitar, band, beatSynth, empty]

    // MARK: User templates (project JSON in Application Support/Templates)

    public static func userTemplates(folder: URL = AppPaths.templates) -> [ProjectTemplate] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let p = try? ProjectPackage.decoder().decode(Project.self, from: data) else { return nil }
            let tracks = p.tracks.map { t -> Track in var t = t; t.audioClips = []; return t }
            return ProjectTemplate(id: "user:" + url.deletingPathExtension().lastPathComponent, name: p.name,
                                   summary: "User template", symbol: "person.crop.square", tempo: p.tempo,
                                   timeSignature: p.timeSignature, tracks: tracks, beatStyle: nil)
        }
    }

    /// Saves the current project's track layout (without audio) as a user template.
    public static func saveAsTemplate(_ project: Project, name: String, folder: URL = AppPaths.templates) throws {
        var p = project
        p.name = name
        for i in p.tracks.indices { p.tracks[i].audioClips = [] }
        let url = ProjectPackage.uniqueURL(in: folder, baseName: name, ext: "json")
        try ProjectPackage.encoder().encode(p).write(to: url, options: .atomic)
    }
}
