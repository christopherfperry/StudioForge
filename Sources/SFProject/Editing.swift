import Foundation
import SFCore

/// Pure clip-editing operations used by the arrangement view. All functions return new values,
/// which keeps them trivially undoable and unit-testable.
public enum ClipEditing {
    public static let minimumClipLength = 0.01

    /// Splits an audio clip at a timeline time. Returns nil if the time is outside the clip.
    public static func split(_ clip: AudioClip, at time: Double) -> (AudioClip, AudioClip)? {
        guard time > clip.start + minimumClipLength, time < clip.end - minimumClipLength else { return nil }
        var left = clip, right = clip
        left.duration = time - clip.start
        left.fadeOut = min(clip.fadeOut, left.duration)
        left.fadeIn = min(clip.fadeIn, left.duration)
        right.id = UUID()
        right.start = time
        right.offset = clip.offset + (time - clip.start)
        right.duration = clip.end - time
        right.fadeIn = 0
        right.fadeOut = min(clip.fadeOut, right.duration)
        left.fadeOut = 0
        return (left, right)
    }

    /// Moves the clip start edge to `newStart` keeping the audio anchored (trim/extend left).
    /// `sourceLength` limits extension to the available audio.
    public static func trimStart(_ clip: AudioClip, to newStart: Double, sourceLength: Double? = nil) -> AudioClip {
        var c = clip
        let maxStart = clip.end - minimumClipLength
        let minStart = clip.start - clip.offset   // cannot extend before the beginning of the file
        let s = min(maxStart, max(minStart, newStart))
        c.offset = clip.offset + (s - clip.start)
        c.start = s
        c.duration = clip.end - s
        c.fadeIn = min(c.fadeIn, c.duration)
        _ = sourceLength
        return c
    }

    /// Moves the clip end edge (trim/extend right).
    public static func trimEnd(_ clip: AudioClip, to newEnd: Double, sourceLength: Double? = nil) -> AudioClip {
        var c = clip
        var e = max(clip.start + minimumClipLength, newEnd)
        if let len = sourceLength { e = min(e, clip.start + (len - clip.offset)) }
        c.duration = e - clip.start
        c.fadeOut = min(c.fadeOut, c.duration)
        return c
    }

    public static func move(_ clip: AudioClip, to start: Double) -> AudioClip {
        var c = clip; c.start = max(0, start); return c
    }

    public static func setFades(_ clip: AudioClip, fadeIn: Double? = nil, fadeOut: Double? = nil) -> AudioClip {
        var c = clip
        if let f = fadeIn { c.fadeIn = max(0, min(f, c.duration - c.fadeOut)) }
        if let f = fadeOut { c.fadeOut = max(0, min(f, c.duration - c.fadeIn)) }
        return c
    }

    /// Splits a MIDI clip at an absolute beat; notes are assigned by start position and the
    /// left notes are truncated at the split point.
    public static func split(_ clip: MIDIClip, atBeat beat: Double) -> (MIDIClip, MIDIClip)? {
        let rel = beat - clip.startBeat
        guard rel > 0.001, rel < clip.lengthBeats - 0.001 else { return nil }
        var left = clip, right = clip
        right.id = UUID()
        left.lengthBeats = rel
        left.notes = clip.notes.filter { $0.startBeat < rel }.map { n in
            var m = n; m.durationBeats = min(n.durationBeats, rel - n.startBeat); return m
        }
        right.startBeat = beat
        right.lengthBeats = clip.lengthBeats - rel
        right.notes = clip.notes.filter { $0.startBeat >= rel }.map { n in
            var m = n; m.id = UUID(); m.startBeat -= rel; return m
        }
        return (left, right)
    }

    /// Quantises note starts to a grid (in beats) with a strength 0...1.
    public static func quantize(_ notes: [MIDINote], grid: Double, strength: Double = 1) -> [MIDINote] {
        guard grid > 0 else { return notes }
        return notes.map { n in
            var m = n
            let target = (n.startBeat / grid).rounded() * grid
            m.startBeat = n.startBeat + (target - n.startBeat) * max(0, min(1, strength))
            return m
        }
    }
}

extension Project {
    /// Splits every clip under `time` on the given tracks (or all tracks).
    public mutating func splitClips(at time: Double, trackIDs: Set<UUID>? = nil) {
        let beat = beats(forSeconds: time)
        for i in tracks.indices where trackIDs?.contains(tracks[i].id) ?? true {
            var newAudio: [AudioClip] = []
            for c in tracks[i].audioClips {
                if let (a, b) = ClipEditing.split(c, at: time) { newAudio += [a, b] } else { newAudio.append(c) }
            }
            tracks[i].audioClips = newAudio
            var newMIDI: [MIDIClip] = []
            for c in tracks[i].midiClips {
                if let (a, b) = ClipEditing.split(c, atBeat: beat) { newMIDI += [a, b] } else { newMIDI.append(c) }
            }
            tracks[i].midiClips = newMIDI
        }
    }

    /// Finds an audio clip by id: (track index, clip index).
    public func locateAudioClip(_ id: UUID) -> (Int, Int)? {
        for (ti, t) in tracks.enumerated() { if let ci = t.audioClips.firstIndex(where: { $0.id == id }) { return (ti, ci) } }
        return nil
    }

    public func locateMIDIClip(_ id: UUID) -> (Int, Int)? {
        for (ti, t) in tracks.enumerated() { if let ci = t.midiClips.firstIndex(where: { $0.id == id }) { return (ti, ci) } }
        return nil
    }

    public mutating func deleteClip(_ id: UUID) {
        if let (t, c) = locateAudioClip(id) { tracks[t].audioClips.remove(at: c) }
        else if let (t, c) = locateMIDIClip(id) { tracks[t].midiClips.remove(at: c) }
    }

    /// Removes tracks by id. Returns how many were removed.
    @discardableResult
    public mutating func deleteTracks(_ ids: Set<UUID>) -> Int {
        let before = tracks.count
        tracks.removeAll { ids.contains($0.id) }
        return before - tracks.count
    }

    /// Ids of every stem track produced by the same split as `id` (empty if it isn't a stem).
    public func stemSiblings(of id: UUID) -> Set<UUID> {
        guard let g = tracks.first(where: { $0.id == id })?.stemGroup else { return [] }
        return Set(tracks.filter { $0.stemGroup == g }.map(\.id))
    }

    /// Ids of all stem tracks in the project.
    public var allStemTrackIDs: Set<UUID> { Set(tracks.filter(\.isStem).map(\.id)) }

    /// Adds a new track with a sensible default name and colour.
    @discardableResult
    public mutating func addTrack(kind: TrackKind, name: String? = nil, instrument: InstrumentState? = nil) -> UUID {
        let n = name ?? "\(kind.displayName) \(tracks.filter { $0.kind == kind }.count + 1)"
        var t = Track(name: n, kind: kind, colorIndex: tracks.count % 12)
        if let inst = instrument { t.instrument = inst }
        else if kind == .drums { t.instrument = InstrumentState(type: "drums") }
        else if kind == .instrument { t.instrument = InstrumentState(type: "synth.subtractive") }
        tracks.append(t)
        return t.id
    }

    /// One separated stem to place on its own audio track.
    public struct StemTrackSpec: Equatable {
        public var name: String
        public var file: String
        public var fileDuration: Double
        public init(name: String, file: String, fileDuration: Double) {
            self.name = name; self.file = file; self.fileDuration = fileDuration
        }
    }

    /// Adds one audio track per stem in a single mutation (one undo step). Each stem clip copies
    /// the source clip's timeline placement (`start`, `offset`, `duration`), so a split of a trimmed
    /// clip lines up sample-accurately with the original. Tracks are inserted after `afterTrack`
    /// (or at the end) and share one colour; `muteTrack` is muted so the stems replace the mix.
    @discardableResult
    public mutating func addStemTracks(_ stems: [StemTrackSpec], start: Double, offset: Double = 0,
                                       duration: Double? = nil, afterTrack: UUID? = nil,
                                       muteTrack: UUID? = nil) -> [UUID] {
        guard !stems.isEmpty else { return [] }
        var insertAt = tracks.count
        if let a = afterTrack, let i = trackIndex(a) { insertAt = i + 1 }
        let color = tracks.count % 12
        let group = UUID().uuidString
        var ids: [UUID] = []
        for (k, s) in stems.enumerated() {
            var t = Track(name: s.name, kind: .audio, colorIndex: color)
            t.stemGroup = group
            let off = max(0, min(offset, s.fileDuration))
            let len = max(0, min(duration ?? (s.fileDuration - off), s.fileDuration - off))
            var clip = AudioClip(name: s.name, file: s.file, start: max(0, start), offset: off, duration: len)
            clip.fadeIn = 0; clip.fadeOut = 0
            t.audioClips = [clip]
            tracks.insert(t, at: min(insertAt + k, tracks.count))
            ids.append(t.id)
        }
        if let m = muteTrack, let i = trackIndex(m) { tracks[i].mute = true }
        return ids
    }
}

/// Snapshot-based undo/redo. Projects are value types, so a snapshot is a copy; clip audio lives
/// on disk and is never duplicated.
public struct UndoStack {
    public struct Entry { public var label: String; public var project: Project }
    public private(set) var undoEntries: [Entry] = []
    public private(set) var redoEntries: [Entry] = []
    public var limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoLabel: String? { undoEntries.last?.label }
    public var redoLabel: String? { redoEntries.last?.label }

    /// Record the state *before* a change.
    public mutating func record(_ before: Project, label: String) {
        undoEntries.append(Entry(label: label, project: before))
        if undoEntries.count > limit { undoEntries.removeFirst(undoEntries.count - limit) }
        redoEntries.removeAll()
    }

    /// Returns the project to restore, given the current one.
    public mutating func undo(current: Project) -> Project? {
        guard let e = undoEntries.popLast() else { return nil }
        redoEntries.append(Entry(label: e.label, project: current))
        return e.project
    }

    public mutating func redo(current: Project) -> Project? {
        guard let e = redoEntries.popLast() else { return nil }
        undoEntries.append(Entry(label: e.label, project: current))
        return e.project
    }

    public mutating func clear() { undoEntries.removeAll(); redoEntries.removeAll() }
}
