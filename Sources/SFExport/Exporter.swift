import Foundation
import SFCore
import SFEngine
import SFProject
import SFBeatGen

/// Offline bounce + post-processing (normalize, dither) + encoding for master and stem exports.
public struct Exporter {
    public struct Result {
        public var files: [URL] = []
        public var warnings: [String] = []
    }

    public typealias Progress = (_ fraction: Double, _ message: String) -> Void

    public init() {}

    /// Resolves the export range to seconds (start, end) for the given project.
    public static func bounds(_ range: ExportRange, project: Project) -> (Double, Double) {
        switch range {
        case .wholeProject: return (0, max(0.1, project.contentEnd))
        case .loop: return project.loop.isValid ? (project.loop.start, project.loop.end) : (0, max(0.1, project.contentEnd))
        case .custom(let s, let e): return (max(0, s), max(max(0, s) + 0.01, e))
        }
    }

    /// Exports according to `settings` into `folder`. File names start with `baseName`.
    public func export(project: Project, packageURL: URL?, settings: ExportSettings, folder: URL, baseName: String,
                       progress: Progress? = nil, isCancelled: @escaping () -> Bool = { false }) throws -> Result {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result = Result()
        let (start, end) = Self.bounds(settings.range, project: project)
        var opts = OfflineRenderer.Options()
        opts.sampleRate = settings.sampleRate ?? project.sampleRate
        opts.start = start
        opts.end = end
        opts.tail = settings.range == .wholeProject ? settings.tailSeconds : 0
        let renderer = OfflineRenderer()
        let ext = settings.format.fileExtension
        let doMaster = settings.content != .stems
        let doStems = settings.content != .master
        let masterShare = doMaster && doStems ? 0.3 : (doMaster ? 1 : 0)

        if doMaster {
            progress?(0, "Bouncing master…")
            var audio = try renderer.renderMaster(project: project, packageURL: packageURL, options: opts,
                                                  progress: { p in progress?(p * masterShare * 0.9, "Bouncing master…") },
                                                  isCancelled: isCancelled)
            result.warnings += Self.postProcess(&audio, settings: settings, label: "Master")
            let url = ProjectPackage.uniqueURL(in: folder, baseName: Self.sanitize(baseName), ext: ext)
            progress?(masterShare * 0.95, "Encoding \(settings.format.displayName)…")
            try AudioEncoders.encode(audio, to: url, settings: settings)
            result.files.append(url)
        }
        if doStems {
            var o = opts
            o.includeMasterChain = settings.stemsThroughMaster
            let stems = try renderer.renderStems(project: project, packageURL: packageURL, options: o,
                                                 progress: { p in progress?(masterShare + p * (1 - masterShare) * 0.9, "Bouncing stems…") },
                                                 isCancelled: isCancelled)
            let stemFolder = folder.appendingPathComponent("\(Self.sanitize(baseName)) Stems", isDirectory: true)
            try FileManager.default.createDirectory(at: stemFolder, withIntermediateDirectories: true)
            for (i, stem) in stems.enumerated() {
                if isCancelled() { throw StudioForgeError.cancelled }
                var audio = stem.audio
                result.warnings += Self.postProcess(&audio, settings: settings, label: stem.track.name)
                let name = String(format: "%02d %@", i + 1, Self.sanitize(stem.track.name))
                let url = ProjectPackage.uniqueURL(in: stemFolder, baseName: name, ext: ext)
                try AudioEncoders.encode(audio, to: url, settings: settings)
                result.files.append(url)
            }
        }
        if settings.includeMIDI, Self.hasMIDI(project) {
            let url = ProjectPackage.uniqueURL(in: folder, baseName: Self.sanitize(baseName), ext: "mid")
            try Self.writeMIDI(project: project, to: url)
            result.files.append(url)
        }
        progress?(1, "Done")
        return result
    }

    /// Normalise (optional) and dither (integer formats). Returns warnings (e.g. clipping).
    public static func postProcess(_ audio: inout AudioData, settings: ExportSettings, label: String) -> [String] {
        var warnings: [String] = []
        let peak = audio.peak
        if settings.normalize, peak > 1e-6 {
            let target = dbToGain(settings.normalizePeakDB)
            let g = target / peak
            for c in 0..<audio.channels.count { for i in 0..<audio.channels[c].count { audio.channels[c][i] *= g } }
        } else if peak > 1.0001 && !settings.effectiveSampleFormat.isFloat {
            warnings.append("\(label): peak \(String(format: "%.1f", 20 * log10f(peak))) dBFS — the file will clip. Enable Normalize or lower the master.")
        }
        if let bits = settings.ditherBits { Dither.tpdf(&audio, bits: bits) }
        return warnings
    }

    // MARK: MIDI

    public static func hasMIDI(_ p: Project) -> Bool {
        p.tracks.contains { $0.kind != .audio && $0.midiClips.contains { !$0.notes.isEmpty } }
    }

    /// Converts all instrument/drum track clips into MIDI file tracks (drums on channel 10).
    public static func midiTracks(for project: Project) -> [MIDIFile.Track] {
        var tracks: [MIDIFile.Track] = []
        var channel = 0
        for t in project.tracks where t.kind != .audio {
            var notes: [MIDINote] = []
            for clip in t.midiClips where !clip.muted {
                for n in clip.notes where n.startBeat < clip.lengthBeats {
                    var m = n
                    m.startBeat = clip.startBeat + n.startBeat
                    m.durationBeats = min(n.durationBeats, clip.lengthBeats - n.startBeat)
                    notes.append(m)
                }
            }
            guard !notes.isEmpty else { continue }
            let ch: Int
            if t.kind == .drums { ch = 9 } else { ch = channel; channel = (channel + 1) % 16; if channel == 9 { channel = 10 } }
            tracks.append(MIDIFile.Track(name: t.name, channel: ch, notes: notes.sorted { $0.startBeat < $1.startBeat }))
        }
        return tracks
    }

    public static func writeMIDI(project: Project, to url: URL) throws {
        let tracks = midiTracks(for: project)
        guard !tracks.isEmpty else { throw StudioForgeError.invalid("The project has no MIDI notes to export.") }
        try MIDIFile.write(tracks: tracks, tempo: project.tempo, timeSignature: project.timeSignature, to: url)
    }

    /// Exports one MIDI clip (e.g. a generated beat) to a .mid file.
    public static func writeMIDI(clip: MIDIClip, trackName: String, drums: Bool, tempo: Double,
                                 timeSignature: TimeSignature, to url: URL) throws {
        let track = MIDIFile.Track(name: trackName, channel: drums ? 9 : 0, notes: clip.notes)
        try MIDIFile.write(tracks: [track], tempo: tempo, timeSignature: timeSignature, to: url)
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Export" : cleaned
    }
}
