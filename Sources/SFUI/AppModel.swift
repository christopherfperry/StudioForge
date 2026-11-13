#if os(macOS)
import Foundation
import SwiftUI
import AppKit
import SFCore
import SFEngine
import SFProject
import SFPresets
import SFBeatGen
import SFSeparation
import SFExport

/// Main-thread document + engine model shared by all views.
public final class AppModel: ObservableObject {
    @Published public private(set) var project: Project
    @Published public var packageURL: URL?
    @Published public var selectedTrackID: UUID? { didSet { engine.selectedTrackID = selectedTrackID } }
    @Published public var isDirty = false
    @Published public var status = "Ready"
    @Published public var position: Double = 0
    @Published public var isPlaying = false
    @Published public var isRecording = false
    @Published public var cpu: Float = 0
    @Published public var masterPeak: Float = 0
    @Published public var zoom: Double = 60          // pixels per second
    @Published public var showOnboarding = false
    /// First-launch welcome (folders + microphone permission). Shown before the onboarding tour.
    @Published public var showWelcome = false
    @Published public var showSetup = false
    /// Opens the "Import & Split Audio" sheet (menu ⇧⌘I, toolbar "Split").
    @Published public var showSplitSheet = false
    /// "Show Playing Notes" (transport "Notes" toggle, N, View menu). Persisted between launches.
    @Published public var showNotes = UserDefaults.standard.bool(forKey: "SFShowNotes") {
        didSet {
            UserDefaults.standard.set(showNotes, forKey: "SFShowNotes")
            if showNotes { refreshNotes() } else { playingNotes = [:] }
        }
    }
    /// Track id → label of the note(s) sounding at the playhead ("C4", "C4 E4 G4", "Kick + Snare").
    @Published public private(set) var playingNotes: [UUID: String] = [:]
    /// Pitch tracks of audio files (keyed by resolved path), built in the background on demand.
    private var pitchContours: [String: PitchContour] = [:]
    private var pitchPending: Set<String> = []
    private let pitchQueue = DispatchQueue(label: "fitzrovia.pitch", qos: .utility)
    public let permissions = PermissionsModel()
    @Published public var audioConfig = CoreAudioIO.Configuration()

    public let io = CoreAudioIO()
    public let engine: EngineController
    public let presets = PresetLibrary.shared
    public let beatStyles = BeatStyleLibrary.shared
    private var undo = UndoStack()
    private var midi: MIDIInputManager?
    private var timer: Timer?
    private var autosave: AutosaveController?

    public init() {
        AppleAudioDecoding.register()
        project = ProjectTemplates.vocals.makeProject(name: "Untitled")
        engine = EngineController(io: io)
        engine.load(project: project, packageURL: nil)
        if FirstRunSetup.isNeeded { FirstRunSetup.run() }
        permissions.refresh()
        permissions.onAuthorized = { [weak self] in self?.restartAudio() }
        if permissions.mic == .authorized {
            restartAudio()
        } else if permissions.mic == .notDetermined || !UserDefaults.standard.bool(forKey: "SFWelcomeDone") {
            // Ask with an explanation screen first instead of a bare system prompt.
            showWelcome = true
        } else {
            restartAudio()   // output-only until input access is granted in System Settings
        }
        showOnboarding = !showWelcome && !UserDefaults.standard.bool(forKey: "SFOnboardingDone")
        let m = MIDIInputManager(queue: engine.core.midiQueue)
        try? m.start()
        midi = m
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // AutosaveController invokes these closures on the main thread.
        let a = AutosaveController(currentProject: { [weak self] in self?.project },
                                   packageURL: { [weak self] in self?.packageURL },
                                   isDirty: { [weak self] in self?.isDirty ?? false })
        a.start()
        autosave = a
    }

    // MARK: Audio

    public func restartAudio() {
        io.configuration = audioConfig
        engine.startAudio()
        midi?.retarget(engine.core.midiQueue)
        status = engine.lastError ?? io.statusMessage
    }

    private func tick() {
        position = engine.positionSeconds
        isPlaying = engine.isPlaying
        isRecording = engine.isRecording
        let m = engine.readMeters()
        cpu = m.cpu
        masterPeak = max(m.masterL, m.masterR)
        engine.collectGarbage()
        if showNotes { refreshNotes() }
    }

    // MARK: Playing notes

    /// Recomputes the per-track note labels at the playhead. MIDI/drum tracks read their clips;
    /// audio tracks use a background-computed pitch track (monophonic: one note per track).
    func refreshNotes() {
        let t = position
        var out: [UUID: String] = [:]
        let anySolo = project.anySolo
        for track in project.tracks where track.isAudible(anySolo: anySolo) {
            if !track.midiClips.isEmpty {
                let label = NoteName.label(for: project.soundingMIDIPitches(track: track, at: t), drums: track.kind == .drums)
                if !label.isEmpty { out[track.id] = label; continue }
            }
            if let hit = project.audioClipPosition(track: track, at: t) {
                let path = ProjectPackage.resolve(hit.clip.file, in: packageURL).standardizedFileURL.path
                if let contour = pitchContours[path] {
                    if let n = contour.note(at: hit.fileTime) { out[track.id] = NoteName.name(n) }
                } else {
                    requestPitchContour(path)
                }
            }
        }
        if out != playingNotes { playingNotes = out }
    }

    private func requestPitchContour(_ path: String) {
        guard !pitchPending.contains(path) else { return }
        pitchPending.insert(path)
        pitchQueue.async { [weak self] in
            // Unreadable files get an empty contour so they are not retried every frame.
            let c = (try? AudioDecoding.decode(URL(fileURLWithPath: path))).map { PitchTracker.contour($0) }
                ?? PitchContour(hopSeconds: 1, notes: [])
            DispatchQueue.main.async {
                self?.pitchContours[path] = c
                self?.pitchPending.remove(path)
            }
        }
    }

    // MARK: Document editing (every change is undoable)

    public func edit(_ label: String, _ change: (inout Project) -> Void) {
        let before = project
        var p = project
        change(&p)
        guard p != before else { return }
        undo.record(before, label: label)
        p.modifiedAt = Date()
        project = p
        isDirty = true
        engine.update(project: p)
    }

    public var canUndo: Bool { undo.canUndo }
    public var canRedo: Bool { undo.canRedo }
    public func undoAction() { if let p = undo.undo(current: project) { project = p; engine.update(project: p); isDirty = true } }
    public func redoAction() { if let p = undo.redo(current: project) { project = p; engine.update(project: p); isDirty = true } }

    public func binding<T>(track id: UUID, _ kp: WritableKeyPath<Track, T>, label: String) -> Binding<T>? where T: Equatable {
        // Look the track up by id on every access: capturing the index edited the wrong track after
        // tracks were added, deleted or reordered while a view still held the binding.
        guard let i = project.trackIndex(id) else { return nil }
        var last = project.tracks[i][keyPath: kp]
        return Binding(get: { [weak self] in
                           guard let self = self, let j = self.project.trackIndex(id) else { return last }
                           last = self.project.tracks[j][keyPath: kp]
                           return last
                       },
                       set: { [weak self] v in
                           self?.edit(label) { p in if let j = p.trackIndex(id) { p.tracks[j][keyPath: kp] = v } }
                       })
    }

    // MARK: Transport

    public func togglePlay() {
        if engine.isPlaying { stop() } else { engine.play() }
    }
    public func stop() {
        let takes = engine.stop()
        if !takes.isEmpty { edit("Record") { p in p = engine.applyTakes(takes, to: p) } }
        if let e = engine.lastError { status = e }
    }
    public func record() { if !engine.record() { status = engine.lastError ?? "Cannot record" } }
    public func rewind() { engine.seek(seconds: 0) }

    // MARK: Projects

    public func newProject(from template: ProjectTemplate) {
        var p = template.makeProject(name: "Untitled", sampleRate: engine.sampleRate)
        presets.applyReferencedPresets(to: &p)
        if let styleID = template.beatStyle, let style = beatStyles.style(id: styleID),
           let drums = p.tracks.firstIndex(where: { $0.kind == .drums }) {
            var s = BeatSettings(tempo: p.tempo, bars: 8)
            s.swing = style.defaultSwing
            let beat = BeatGenerator().generate(style: style, settings: s)
            p.tracks[drums].midiClips = [MIDIClip(name: style.name, startBeat: 0, lengthBeats: beat.lengthBeats, notes: beat.notes)]
        }
        undo.clear()
        project = p; packageURL = nil; isDirty = false
        engine.load(project: p, packageURL: nil)
    }

    public func open(_ url: URL) {
        do {
            let p = try ProjectPackage.newerAutosave(in: url) ?? ProjectPackage.load(from: url)
            undo.clear(); project = p; packageURL = url; isDirty = false
            engine.load(project: p, packageURL: url)
            RecentProjects.shared.add(url)
        } catch { status = "Open failed: \(error.localizedDescription)" }
    }

    public func save(as url: URL? = nil) {
        guard let target = url ?? packageURL ?? askSaveURL() else { return }
        do {
            try ProjectPackage.save(project, to: target)
            if packageURL != target {
                // Copy recordings/imports that lived outside the package into it — including audio
                // that lived in the *previous* package on Save As (previously left behind, which
                // broke every clip in the new copy).
                let p = ProjectPackage.relocateClips(project, from: packageURL, to: target)
                project = p
                try ProjectPackage.save(p, to: target)
                packageURL = target
                engine.load(project: p, packageURL: target)
            }
            RecentProjects.shared.add(target)
            isDirty = false
            status = "Saved \(target.lastPathComponent)"
        } catch { status = "Save failed: \(error.localizedDescription)" }
    }

    /// Save As: always asks for a new location; audio from the old package is copied along.
    public func saveAs() { if let u = askSaveURL() { save(as: u) } }

    private func askSaveURL() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name).\(ProjectPackage.fileExtension)"
        panel.directoryURL = AppPaths.defaultProjectsFolder
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Import / tracks

    /// Imports audio files as new tracks in ONE undo step. Files already inside the project
    /// package are referenced instead of copied again.
    public func importAudio(_ urls: [URL], at time: Double = 0) {
        var added: [(name: String, clip: String, file: String, duration: Double)] = []
        var failures: [String] = []
        for url in urls {
            do {
                let audio = try AudioDecoding.decode(url)
                let file = try ProjectPackage.adopt(url, into: packageURL)
                added.append((url.deletingPathExtension().lastPathComponent, url.lastPathComponent, file, audio.duration))
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !added.isEmpty {
            edit(added.count == 1 ? "Import Audio" : "Import \(added.count) Audio Files") { p in
                for a in added {
                    let id = p.addTrack(kind: .audio, name: a.name)
                    if let i = p.trackIndex(id) {
                        p.tracks[i].audioClips.append(AudioClip(name: a.clip, file: a.file, start: max(0, time), duration: a.duration))
                    }
                }
            }
        }
        status = failures.isEmpty ? "Imported \(added.count) file(s)" : "Import failed: " + failures.joined(separator: "; ")
    }

    // MARK: Import & split

    /// What a split works on: a file from disk, or an existing clip on the timeline.
    public struct SplitSource {
        public var url: URL
        public var displayName: String
        public var start: Double
        public var offset: Double
        public var duration: Double?
        public var trackID: UUID?
    }

    /// The selected track's first audio clip (if any) as a split source.
    public var selectedClipSplitSource: SplitSource? {
        guard let t = project.tracks.first(where: { $0.id == selectedTrackID }), t.kind == .audio,
              let c = t.audioClips.first else { return nil }
        return SplitSource(url: ProjectPackage.resolve(c.file, in: packageURL), displayName: c.name,
                           start: c.start, offset: c.offset, duration: c.duration, trackID: t.id)
    }

    /// Where new stem files are written: inside the open project, or the library's Stems folder.
    public var stemOutputFolder: URL {
        packageURL?.appendingPathComponent(ProjectPackage.audioFolder) ?? AppPaths.sub("Stems")
    }

    /// Adds separated stems as new tracks in one undo step ("Split into Stems"), aligned with the source.
    public func addSeparatedStems(_ files: [Stem: URL], durations: [Stem: Double], source: SplitSource, muteSource: Bool) {
        var specs: [Project.StemTrackSpec] = []
        var failed = 0
        for (stem, url) in files.sorted(by: { $0.key.sortIndex < $1.key.sortIndex }) {
            guard let file = try? ProjectPackage.adopt(url, into: packageURL) else { failed += 1; continue }
            specs.append(Project.StemTrackSpec(name: "\(source.displayName) – \(stem.displayName)", file: file,
                                               fileDuration: durations[stem] ?? (source.duration ?? 0)))
        }
        guard !specs.isEmpty else { status = "No stems were added."; return }
        var firstID: UUID?
        edit("Split into Stems") { p in
            let ids = p.addStemTracks(specs, start: source.start, offset: source.offset, duration: source.duration,
                                      afterTrack: source.trackID, muteTrack: muteSource ? source.trackID : nil)
            firstID = ids.first
        }
        if let f = firstID { selectedTrackID = f }
        status = "Added \(specs.count) stem tracks" + (failed > 0 ? " (\(failed) could not be added)" : "")
    }

    public func addTrack(_ kind: TrackKind) { edit("Add Track") { p in selectedTrackID = p.addTrack(kind: kind) } }

    public func splitAtPlayhead() { edit("Split") { p in p.splitClips(at: position) } }

    public func apply(preset: Preset, to trackID: UUID) {
        edit("Apply Preset \(preset.name)") { p in if let i = p.trackIndex(trackID) { preset.apply(to: &p.tracks[i]) } }
    }

    public func setParameter(track: UUID, effect: UUID, id: String, value: Float) {
        engine.setParameter(track: track, slot: effect, id: id, value: value)
        edit("Change \(id)") { p in
            if let ti = p.trackIndex(track), let ei = p.tracks[ti].effects.firstIndex(where: { $0.id == effect }) {
                p.tracks[ti].effects[ei].params[id] = value
            }
        }
    }

    // MARK: Beat generator

    public func insertBeat(style: BeatStyle, settings: BeatSettings, at beat: Double = 0) {
        let g = BeatGenerator().generate(style: style, settings: settings)
        edit("Generate Beat") { p in
            var ti = p.tracks.firstIndex { $0.kind == .drums } ?? -1
            if ti < 0 { let id = p.addTrack(kind: .drums, name: "Beat"); ti = p.trackIndex(id) ?? 0 }
            p.tracks[ti].midiClips.append(MIDIClip(name: style.name, startBeat: beat, lengthBeats: g.lengthBeats, notes: g.notes))
            if let kit = style.kitPreset, let pr = presets.preset(id: kit) { pr.apply(to: &p.tracks[ti]) }
        }
    }

    /// Analyses the selected (or first) audio track's clips and drops a matching beat.
    public func matchBeat(styleHint: String?) {
        guard let t = project.tracks.first(where: { $0.id == selectedTrackID && $0.kind == .audio }) ?? project.tracks.first(where: { $0.kind == .audio && !$0.audioClips.isEmpty }),
              let clip = t.audioClips.first else { status = "Record or import audio first."; return }
        let url = ProjectPackage.resolve(clip.file, in: packageURL)
        let styles = beatStyles.styles
        status = "Analysing \(clip.name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = (try? AudioDecoding.decode(url)).flatMap { BeatMatcher().match(audio: $0, styles: styles, genreHint: styleHint) }
            DispatchQueue.main.async {
                guard let r = result else { self.status = "Could not analyse the recording."; return }
                self.edit("Set Tempo") { $0.tempo = r.analysis.bpm.rounded() }
                self.insertBeat(style: r.beat.style, settings: r.beat.settings, at: max(0, clip.start / self.project.secondsPerBeat + r.startOffsetBeats))
                self.status = String(format: "Matched %.1f BPM, key %@ — style %@", r.analysis.bpm, r.analysis.key, r.beat.style.name)
            }
        }
    }

    // MARK: Matching synth generator

    /// The part of a decoded file that a clip actually plays (offset / duration in seconds).
    public static func slice(_ audio: AudioData, offset: Double, duration: Double?) -> AudioData {
        let sr = audio.sampleRate
        let a = max(0, min(audio.frameCount, Int(offset * sr)))
        let b = duration.map { max(a, min(audio.frameCount, a + Int($0 * sr))) } ?? audio.frameCount
        guard a > 0 || b < audio.frameCount else { return audio }
        return AudioData(channels: audio.channels.map { Array($0[a..<b]) }, sampleRate: sr)
    }

    /// Builds a synth part from guitar and/or bass audio (call off the main thread).
    public static func makeSynthPart(style: SynthStyle, guitar: AudioData?, bass: AudioData?,
                                     tempo: Double, beatsPerBar: Int) -> SynthGenerationResult? {
        guard guitar != nil || bass != nil else { return nil }
        let r = SynthTrackGenerator(tempo: tempo, beatsPerBar: beatsPerBar).generate(style: style, guitar: guitar, bass: bass)
        return r.notes.isEmpty ? nil : r
    }

    /// Adds a generated synth part as a new instrument track (one undo step).
    public func addGeneratedSynth(_ r: SynthGenerationResult, startSeconds: Double) {
        var newID: UUID?
        edit("Generate Synth Track") { p in
            let id = p.addTrack(kind: .instrument, name: r.trackName, instrument: r.instrument)
            if let i = p.trackIndex(id) {
                p.tracks[i].midiClips.append(MIDIClip(name: "\(r.trackName) (\(r.keyName))",
                                                      startBeat: p.beats(forSeconds: startSeconds),
                                                      lengthBeats: r.lengthBeats, notes: r.notes))
            }
            newID = id
        }
        if let id = newID { selectedTrackID = id }
        status = "Added \(r.trackName): \(r.notes.count) notes, key \(r.keyName), \(r.chords.count) chord changes"
    }

    /// Guitar / bass audio tracks used by "Generate Matching Synth": tracks named "guitar" or "bass",
    /// falling back to the selected audio track.
    func synthSourceClips() -> (guitar: (URL, AudioClip)?, bass: (URL, AudioClip)?) {
        func first(_ word: String) -> (URL, AudioClip)? {
            guard let t = project.tracks.first(where: { $0.kind == .audio && !$0.audioClips.isEmpty
                && $0.name.lowercased().contains(word) }), let c = t.audioClips.first else { return nil }
            return (ProjectPackage.resolve(c.file, in: packageURL), c)
        }
        var g = first("guitar"), b = first("bass")
        if g == nil && b == nil, let t = project.tracks.first(where: { $0.id == selectedTrackID && $0.kind == .audio }),
           let c = t.audioClips.first {
            g = (ProjectPackage.resolve(c.file, in: packageURL), c)
        }
        return (g, b)
    }

    /// Style ids and names for menus in modules that don't import SFBeatGen.
    public static let synthStyleMenu: [(id: String, name: String)] = SynthStyle.allCases.map { ($0.rawValue, $0.displayName) }
    public func generateMatchingSynth(styleID: String) {
        generateMatchingSynth(style: SynthStyle(rawValue: styleID) ?? .pad)
    }

    /// Analyses the project's guitar and bass tracks and adds a matching synth track.
    public func generateMatchingSynth(style: SynthStyle) {
        let src = synthSourceClips()
        guard src.guitar != nil || src.bass != nil else {
            status = "Add or select a guitar or bass audio track first."; return
        }
        let tempo = project.tempo, bpb = project.timeSignature.numerator
        let starts = [src.guitar?.1.start, src.bass?.1.start].compactMap { $0 }
        let ref = starts.min() ?? 0
        status = "Analysing guitar / bass for a \(style.trackName.lowercased())…"
        DispatchQueue.global(qos: .userInitiated).async {
            func load(_ s: (URL, AudioClip)?) -> AudioData? {
                guard let (url, clip) = s, let audio = try? AudioDecoding.decode(url) else { return nil }
                var a = AppModel.slice(audio, offset: clip.offset, duration: clip.duration)
                // Pad so both sources share the same time origin (the earliest clip start).
                let pad = Int((clip.start - ref) * a.sampleRate)
                if pad > 0 { a = AudioData(channels: a.channels.map { [Float](repeating: 0, count: pad) + $0 }, sampleRate: a.sampleRate) }
                return a
            }
            let r = AppModel.makeSynthPart(style: style, guitar: load(src.guitar), bass: load(src.bass), tempo: tempo, beatsPerBar: bpb)
            DispatchQueue.main.async {
                guard let r = r else { self.status = "No clear notes or chords found."; return }
                self.addGeneratedSynth(r, startSeconds: ref)
            }
        }
    }

    public func finishWelcome() {
        UserDefaults.standard.set(true, forKey: "SFWelcomeDone")
        showWelcome = false
        if permissions.mic != .authorized { restartAudio() }
        if !UserDefaults.standard.bool(forKey: "SFOnboardingDone") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showOnboarding = true }
        }
    }

    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "SFOnboardingDone")
        showOnboarding = false
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
