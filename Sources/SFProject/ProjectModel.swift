import Foundation
import SFCore

/// Root document model. Plain value types (Codable) so snapshots for undo/redo are cheap and the
/// on-disk JSON manifest is human-readable.
public struct Project: Codable, Hashable {
    public static let currentVersion = 1

    public var version: Int = Project.currentVersion
    public var id: UUID = UUID()
    public var name: String
    public var tempo: Double = 120
    public var timeSignature: TimeSignature = TimeSignature(4, 4)
    public var sampleRate: Double = 48_000
    public var tracks: [Track] = []
    public var master: MasterBus = MasterBus()
    public var loop: TimeRegion = TimeRegion(enabled: false, start: 0, end: 8)
    public var punch: TimeRegion = TimeRegion(enabled: false, start: 4, end: 8)
    public var metronome: MetronomeSettings = MetronomeSettings()
    public var markers: [Marker] = []
    public var createdAt: Date = Date()
    public var modifiedAt: Date = Date()
    public var notes: String = ""

    public init(name: String = "Untitled", tempo: Double = 120, timeSignature: TimeSignature = TimeSignature(4, 4),
                sampleRate: Double = 48_000, tracks: [Track] = []) {
        self.name = name; self.tempo = tempo; self.timeSignature = timeSignature
        self.sampleRate = sampleRate; self.tracks = tracks
    }

    enum CodingKeys: String, CodingKey {
        case version, id, name, tempo, timeSignature, sampleRate, tracks, master, loop, punch, metronome, markers
        case createdAt, modifiedAt, notes
    }

    /// Tolerant decoding: any missing key falls back to its default so older/hand-edited files load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Project()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        tempo = try c.decodeIfPresent(Double.self, forKey: .tempo) ?? d.tempo
        timeSignature = try c.decodeIfPresent(TimeSignature.self, forKey: .timeSignature) ?? d.timeSignature
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? d.sampleRate
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        master = try c.decodeIfPresent(MasterBus.self, forKey: .master) ?? d.master
        loop = try c.decodeIfPresent(TimeRegion.self, forKey: .loop) ?? d.loop
        punch = try c.decodeIfPresent(TimeRegion.self, forKey: .punch) ?? d.punch
        metronome = try c.decodeIfPresent(MetronomeSettings.self, forKey: .metronome) ?? d.metronome
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    // MARK: Time conversion (constant tempo)
    public var secondsPerBeat: Double { 60 / max(1, tempo) }
    public func seconds(forBeat b: Double) -> Double { b * secondsPerBeat }
    public func beats(forSeconds s: Double) -> Double { s / secondsPerBeat }
    public var secondsPerBar: Double { timeSignature.quarterNotesPerBar * secondsPerBeat }

    /// End of the last clip in seconds.
    public var contentEnd: Double {
        var end = 0.0
        for t in tracks {
            for c in t.audioClips { end = max(end, c.end) }
            for m in t.midiClips { end = max(end, seconds(forBeat: m.startBeat + m.lengthBeats)) }
        }
        return end
    }

    public func trackIndex(_ id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }
    public var anySolo: Bool { tracks.contains { $0.solo } }
}

public enum TrackKind: String, Codable, CaseIterable {
    case audio, instrument, drums
    public var displayName: String {
        switch self { case .audio: return "Audio"; case .instrument: return "Instrument"; case .drums: return "Drums" }
    }
}

public enum MonitorMode: String, Codable, CaseIterable {
    /// Never monitor input through the app (use the interface's direct monitoring).
    case off
    /// Monitor while the track is armed (typical).
    case auto
    /// Always monitor input.
    case on
}

/// Which hardware input channels feed a track. `firstChannel` is 0-based on the selected device.
public struct InputSelection: Codable, Hashable {
    public var firstChannel: Int = 0
    public var channelCount: Int = 1   // 1 = mono, 2 = stereo pair
    public init(firstChannel: Int = 0, channelCount: Int = 1) { self.firstChannel = firstChannel; self.channelCount = channelCount }
    public var displayName: String {
        channelCount == 2 ? "In \(firstChannel + 1)+\(firstChannel + 2)" : "In \(firstChannel + 1)"
    }
}

public struct Track: Codable, Hashable, Identifiable {
    public var id: UUID = UUID()
    public var name: String
    public var kind: TrackKind
    public var colorIndex: Int = 0
    public var volumeDB: Float = 0
    public var pan: Float = 0
    public var mute = false
    public var solo = false
    public var arm = false
    public var monitor: MonitorMode = .auto
    /// "Record clean": always true in practice — the dry input is always captured. Kept explicit
    /// so the UI can show it; when false Fitzrovia Records DAW still records dry (never only-wet).
    public var recordClean = true
    /// Additionally capture the processed (wet) signal to a second, linked file.
    public var captureWet = false
    public var input = InputSelection()
    public var effects: [EffectState] = []
    public var instrument: InstrumentState?
    public var audioClips: [AudioClip] = []
    public var midiClips: [MIDIClip] = []
    public var presetID: String?
    public var height: Double = 80
    /// Set on tracks created by one "Split into Stems" run (shared by all stems of that split),
    /// so they can be found and deleted together.
    public var stemGroup: String?
    public var isStem: Bool { stemGroup != nil }

    public init(name: String, kind: TrackKind, colorIndex: Int = 0, effects: [EffectState] = [], instrument: InstrumentState? = nil) {
        self.name = name; self.kind = kind; self.colorIndex = colorIndex; self.effects = effects; self.instrument = instrument
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, colorIndex, volumeDB, pan, mute, solo, arm, monitor, recordClean, captureWet, input
        case effects, instrument, audioClips, midiClips, presetID, height, stemGroup
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Track"
        kind = try c.decodeIfPresent(TrackKind.self, forKey: .kind) ?? .audio
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        volumeDB = try c.decodeIfPresent(Float.self, forKey: .volumeDB) ?? 0
        pan = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        arm = try c.decodeIfPresent(Bool.self, forKey: .arm) ?? false
        monitor = try c.decodeIfPresent(MonitorMode.self, forKey: .monitor) ?? .auto
        recordClean = try c.decodeIfPresent(Bool.self, forKey: .recordClean) ?? true
        captureWet = try c.decodeIfPresent(Bool.self, forKey: .captureWet) ?? false
        input = try c.decodeIfPresent(InputSelection.self, forKey: .input) ?? InputSelection()
        effects = try c.decodeIfPresent([EffectState].self, forKey: .effects) ?? []
        instrument = try c.decodeIfPresent(InstrumentState.self, forKey: .instrument)
        audioClips = try c.decodeIfPresent([AudioClip].self, forKey: .audioClips) ?? []
        midiClips = try c.decodeIfPresent([MIDIClip].self, forKey: .midiClips) ?? []
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 80
        stemGroup = try c.decodeIfPresent(String.self, forKey: .stemGroup)
    }

    /// Whether this track is audible given the global solo state.
    public func isAudible(anySolo: Bool) -> Bool { !mute && (!anySolo || solo) }
}

public enum FadeShape: String, Codable, CaseIterable {
    case linear, equalPower, exponential
    /// Gain for normalised position x in 0...1 of a fade-in.
    public func gain(_ x: Float) -> Float {
        let t = max(0, min(1, x))
        switch self {
        case .linear: return t
        case .equalPower: return sinf(t * .pi / 2)
        case .exponential: return t * t
        }
    }
}

/// An audio region on the timeline referencing a file in the project's Audio folder.
public struct AudioClip: Codable, Hashable, Identifiable {
    public var id: UUID = UUID()
    public var name: String
    /// Path relative to the project package (e.g. "Audio/Take 1.wav") or absolute.
    public var file: String
    /// Timeline position (seconds).
    public var start: Double
    /// Offset into the source file (seconds) — changes when trimming the clip start.
    public var offset: Double = 0
    /// Clip length on the timeline (seconds).
    public var duration: Double
    public var gainDB: Float = 0
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0
    public var fadeShape: FadeShape = .equalPower
    public var muted = false
    /// For wet captures: id of the dry clip recorded at the same time.
    public var linkedDryClip: UUID?
    public var isWetCapture = false

    public init(name: String, file: String, start: Double, offset: Double = 0, duration: Double) {
        self.name = name; self.file = file; self.start = start; self.offset = offset; self.duration = duration
    }

    public var end: Double { start + duration }

    /// Gain envelope (fades) at a timeline time inside the clip.
    public func fadeGain(at time: Double) -> Float {
        let t = time - start
        var g: Float = 1
        if fadeIn > 0, t < fadeIn { g *= fadeShape.gain(Float(t / fadeIn)) }
        if fadeOut > 0, t > duration - fadeOut { g *= fadeShape.gain(Float((duration - t) / fadeOut)) }
        return g
    }
}

/// A MIDI region. Note start times are relative to the clip start (beats).
public struct MIDIClip: Codable, Hashable, Identifiable {
    public var id: UUID = UUID()
    public var name: String
    public var startBeat: Double
    public var lengthBeats: Double
    public var notes: [MIDINote]
    public var muted = false

    public init(name: String, startBeat: Double, lengthBeats: Double, notes: [MIDINote] = []) {
        self.name = name; self.startBeat = startBeat; self.lengthBeats = lengthBeats; self.notes = notes
    }
}

public struct MasterBus: Codable, Hashable {
    public var volumeDB: Float = 0
    public var effects: [EffectState] = []
    public init(volumeDB: Float = 0, effects: [EffectState] = []) { self.volumeDB = volumeDB; self.effects = effects }
}

/// Loop / punch range in seconds.
public struct TimeRegion: Codable, Hashable {
    public var enabled: Bool
    public var start: Double
    public var end: Double
    public init(enabled: Bool, start: Double, end: Double) { self.enabled = enabled; self.start = start; self.end = end }
    public var isValid: Bool { end > start + 0.01 }
    public func contains(_ t: Double) -> Bool { t >= start && t < end }
}

public struct MetronomeSettings: Codable, Hashable {
    public var enabled = false
    public var countInBars = 1
    public var volumeDB: Float = -6
    public var accentFirstBeat = true
    public var onlyWhileRecording = false
    public init() {}
}

public struct Marker: Codable, Hashable, Identifiable {
    public var id: UUID = UUID()
    public var name: String
    public var time: Double
    public init(name: String, time: Double) { self.name = name; self.time = time }
}
