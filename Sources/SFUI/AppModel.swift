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
    /// Opens the New Project window (File › New Project… ⌘N, toolbar "New Project", and at launch).
    @Published public var showNewProject = false
    /// Show the New Project window when the app starts (checkbox in that window).
    @Published public var showNewProjectAtLaunch = UserDefaults.standard.object(forKey: "SFShowNewProjectAtLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNewProjectAtLaunch, forKey: "SFShowNewProjectAtLaunch") }
    }
    /// Mixer panel visibility (transport "Mixer" toggle, X). Persisted between launches.
    @Published public var showMixer = UserDefaults.standard.object(forKey: "SFShowMixer") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMixer, forKey: "SFShowMixer") }
    }
    private var keyMonitor: Any?
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
        // Start window: only when no other first-run sheet is showing (one sheet at a time).
        showNewProject = !showWelcome && !showOnboarding && showNewProjectAtLaunch
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

    /// `coalesce`: continuous gestures (fader drags) with the same label within ~1 s become one undo step.
    public func edit(_ label: String, coalesce: Bool = false, _ change: (inout Project) -> Void) {
        let before = project
        var p = project
        change(&p)
        guard p != before else { return }
        let now = Date()
        if !(coalesce && undo.undoLabel == label && now.timeIntervalSince(lastCoalescedEdit) < 1.0) {
            undo.record(before, label: label)
        }
        lastCoalescedEdit = coalesce ? now : .distantPast
        p.modifiedAt = Date()
        project = p
        isDirty = true
        engine.update(project: p)
    }

    private var lastCoalescedEdit = Date.distantPast

    public var canUndo: Bool { undo.canUndo }
    public var canRedo: Bool { undo.canRedo }
    public var undoMenuTitle: String { undo.undoLabel.map { "Undo \($0)" } ?? "Undo" }
    public var redoMenuTitle: String { undo.redoLabel.map { "Redo \($0)" } ?? "Redo" }
    public func undoAction() {
        guard let p = undo.undo(current: project) else { status = "Nothing to undo."; return }
        restore(p)
    }
    public func redoAction() {
        guard let p = undo.redo(current: project) else { status = "Nothing to redo."; return }
        restore(p)
    }
    private func restore(_ p: Project) {
        project = p; engine.update(project: p); isDirty = true
        lastCoalescedEdit = .distantPast
        // Undoing "Add Track" (or redoing a delete) can remove the selected track.
        if let sel = selectedTrackID, p.trackIndex(sel) == nil { selectedTrackID = p.tracks.first?.id }
    }

    /// Asks before replacing a document with unsaved changes. Returns true to continue.
    public func confirmDiscardChanges(_ action: String) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(project.name)” before you \(action)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return !isDirty
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

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
                           // Coalesced: typing a name or dragging pan is one undo step, not one per keystroke.
                           self?.edit(label, coalesce: true) { p in if let j = p.trackIndex(id) { p.tracks[j][keyPath: kp] = v } }
                       })
    }

    // MARK: Transport

    public func togglePlay() {
        if engine.isPlaying { stop() } else { engine.play() }
    }
    public func stop() {
        let takes = engine.stop()
        if !takes.isEmpty {
            edit("Record") { p in p = engine.applyTakes(takes, to: p) }
            status = "Recorded \(takes.count) take(s) — ⌘Z to undo"
        } else if isRecording {
            status = "Stopped — nothing was recorded."
        }
        if let e = engine.lastError { status = e }
    }
    /// Record button / R: starts recording, or stops if already recording.
    public func record() {
        if engine.isRecording { stop(); return }
        permissions.refresh()
        if permissions.mic == .denied || permissions.mic == .restricted {
            status = "Microphone access is off — allow Fitzrovia Records DAW in System Settings › Privacy & Security › Microphone (Help › Setup & Permissions)."
            return
        }
        if permissions.mic == .notDetermined { showWelcome = true; return }
        if !audioConfig.inputEnabled {
            status = "Audio input is disabled — turn on “Enable audio input” in Audio Settings."
            return
        }
        if engine.record() { status = "Recording…" } else { status = engine.lastError ?? "Cannot record" }
    }
    public func rewind() { engine.seek(seconds: 0) }

    // MARK: Single-key shortcuts
    // Space, Return, R, L, K, N, X and S are handled here instead of as button key equivalents:
    // button shortcuts without modifiers also fired while typing in a text field (renaming a track
    // "drums" started recording and split clips).

    public func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            (self?.handleKey(e) ?? false) ? nil : e
        }
    }

    func handleKey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let w = NSApp.keyWindow, w === NSApp.mainWindow, w.attachedSheet == nil,
              !(w.firstResponder is NSText) else { return false }
        switch e.keyCode {
        case 49: if !e.isARepeat { togglePlay() }; return true      // Space
        case 36, 76: rewind(); return true                            // Return / Enter
        default: break
        }
        guard !e.isARepeat else { return false }
        switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "r": record()
        case "l": edit("Loop") { $0.loop.enabled.toggle() }
        case "k": edit("Metronome") { $0.metronome.enabled.toggle() }
        case "n": showNotes.toggle()
        case "x": showMixer.toggle()
        case "s": splitAtPlayhead()
        default: return false
        }
        return true
    }

    // MARK: Projects

    public func newProject(from template: ProjectTemplate) {
        newProject(from: template, settings: NewProjectSettings(name: "Untitled", tempo: template.tempo,
                                                                timeSignature: template.timeSignature), saveIn: nil)
    }

    /// File › New Project… (⌘N). Builds the project from a template with the user's name, tempo and
    /// time signature; with `saveIn` it is saved straight away as "<name>.sfproj" in that folder
    /// (a unique name is chosen if one exists). Returns false if the user cancelled.
    @discardableResult
    public func newProject(from template: ProjectTemplate, settings: NewProjectSettings, saveIn folder: URL?) -> Bool {
        guard confirmDiscardChanges("start a new project") else { return false }
        var p = template.makeProject(settings: settings, sampleRate: engine.sampleRate)
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
        selectedTrackID = p.tracks.first?.id
        engine.load(project: p, packageURL: nil)
        showNewProject = false
        if let folder = folder {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                save(as: ProjectPackage.uniqueURL(in: folder, baseName: p.name, ext: ProjectPackage.fileExtension))
            } catch { status = "Could not create the project folder: \(error.localizedDescription)" }
            if packageURL != nil { status = "Created “\(project.name)” — saved in \(folder.lastPathComponent)" }
        } else {
            status = "New project “\(p.name)” — ⌘S to save"
        }
        return true
    }

    /// Window title: project name, plus "— Edited" with unsaved changes.
    public var windowTitle: String { project.name + (isDirty ? " — Edited" : "") }

    public func open(_ url: URL) {
        guard url.standardizedFileURL != packageURL?.standardizedFileURL || !isDirty else { return }
        guard confirmDiscardChanges("open another project") else { return }
        do {
            let p = try ProjectPackage.newerAutosave(in: url) ?? ProjectPackage.load(from: url)
            undo.clear(); project = p; packageURL = url; isDirty = false
            selectedTrackID = p.tracks.first?.id
            engine.load(project: p, packageURL: url)
            showNewProject = false
            status = "Opened \(url.deletingPathExtension().lastPathComponent)"
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

    // MARK: Deleting tracks & stems (one undo step each)

    /// Deletes tracks; selection moves to the nearest remaining track.
    public func deleteTracks(_ ids: Set<UUID>, label: String) {
        guard !ids.isEmpty else { return }
        let names = project.tracks.filter { ids.contains($0.id) }.map(\.name)
        let firstIndex = project.tracks.firstIndex { ids.contains($0.id) } ?? 0
        var removed = 0
        edit(label) { p in removed = p.deleteTracks(ids) }
        guard removed > 0 else { return }
        for id in ids { playingNotes[id] = nil }
        if let sel = selectedTrackID, ids.contains(sel) {
            selectedTrackID = project.tracks[safe: min(firstIndex, project.tracks.count - 1)]?.id
        }
        status = (removed == 1 ? "Deleted “\(names.first ?? "track")”" : "Deleted \(removed) tracks") + " — ⌘Z to undo"
    }

    public func deleteTrack(_ id: UUID) {
        let isStem = project.tracks.first { $0.id == id }?.isStem ?? false
        deleteTracks([id], label: isStem ? "Delete Stem" : "Delete Track")
    }
    public func deleteSelectedTrack() {
        if let id = selectedTrackID { deleteTrack(id) } else { status = "Select a track to delete." }
    }
    /// Deletes every stem from the same split as `id`.
    public func deleteStemGroup(of id: UUID) { deleteTracks(project.stemSiblings(of: id), label: "Delete Stems") }
    public func deleteAllStems() {
        let ids = project.allStemTrackIDs
        if ids.isEmpty { status = "There are no stem tracks." } else { deleteTracks(ids, label: "Delete All Stems") }
    }
    public var hasStems: Bool { !project.allStemTrackIDs.isEmpty }

    // MARK: Track volume

    public static let volumeRange: ClosedRange<Float> = -60...6

    // MARK: Mute / solo / arm (read the live document, never a captured view copy)

    public func toggleMute(_ id: UUID) {
        let on = !(project.tracks.first { $0.id == id }?.mute ?? false)
        edit(on ? "Mute" : "Unmute") { $0.toggleMute(id) }
    }
    public func toggleSolo(_ id: UUID) {
        let on = !(project.tracks.first { $0.id == id }?.solo ?? false)
        edit(on ? "Solo" : "Unsolo") { $0.toggleSolo(id) }
    }
    public func toggleArm(_ id: UUID) { edit("Arm") { $0.toggleArm(id) } }
    public func toggleMuteSelected() {
        if let id = selectedTrackID { toggleMute(id) } else { status = "Select a track to mute." }
    }
    public func toggleSoloSelected() {
        if let id = selectedTrackID { toggleSolo(id) } else { status = "Select a track to solo." }
    }
    public func clearAllMuteSolo() {
        edit("Clear Mute & Solo") { p in for i in p.tracks.indices { p.tracks[i].mute = false; p.tracks[i].solo = false } }
    }

    public func setVolume(_ id: UUID, _ db: Float) {
        let v = min(Self.volumeRange.upperBound, max(Self.volumeRange.lowerBound, db))
        edit("Volume", coalesce: true) { p in if let i = p.trackIndex(id) { p.tracks[i].volumeDB = v } }
    }
    public func nudgeVolume(_ id: UUID, by db: Float) {
        guard let t = project.tracks.first(where: { $0.id == id }) else { return }
        setVolume(id, (t.volumeDB + db).rounded())
    }
    public func volumeBinding(_ id: UUID) -> Binding<Float> {
        Binding(get: { [weak self] in self?.project.tracks.first { $0.id == id }?.volumeDB ?? 0 },
                set: { [weak self] v in self?.setVolume(id, v) })
    }
    public var masterVolumeBinding: Binding<Float> {
        Binding(get: { [weak self] in self?.project.master.volumeDB ?? 0 },
                set: { [weak self] v in self?.edit("Master Volume", coalesce: true) { $0.master.volumeDB = v } })
    }

    public func addTrack(_ kind: TrackKind) { edit("Add Track") { p in selectedTrackID = p.addTrack(kind: kind) } }

    public func splitAtPlayhead() {
        let before = project
        edit("Split") { p in p.splitClips(at: position) }
        status = project == before ? "No clip under the playhead to cut — move the playhead over a clip first."
                                   : String(format: "Cut clips at %.2f s — ⌘Z to undo", position)
    }

    public func apply(preset: Preset, to trackID: UUID) {
        edit("Apply Preset \(preset.name)") { p in if let i = p.trackIndex(trackID) { preset.apply(to: &p.tracks[i]) } }
    }

    public func setParameter(track: UUID, effect: UUID, id: String, value: Float) {
        engine.setParameter(track: track, slot: effect, id: id, value: value)
        edit("Change \(id)", coalesce: true) { p in
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
                                     tempo: Double, beatsPerBar: Int, genre: MusicGenre = .auto) -> SynthGenerationResult? {
        guard guitar != nil || bass != nil else { return nil }
        let r = SynthTrackGenerator(tempo: tempo, beatsPerBar: beatsPerBar).generate(style: style, guitar: guitar, bass: bass, genre: genre)
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
        status = "Added \(r.trackName): \(r.notes.count) notes, key \(r.keyName), \(r.chords.count) chord changes — "
            + "\(r.genre.displayName) tone (\(r.genreReason))"
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
    /// Genre used for generated synth tones (persisted; `.auto` detects it from the audio).
    public var synthGenre: MusicGenre {
        get { MusicGenre(rawValue: UserDefaults.standard.string(forKey: "SFSynthGenre") ?? "") ?? .auto }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue.rawValue, forKey: "SFSynthGenre") }
    }
    public static let genreMenu: [(id: String, name: String)] = MusicGenre.allCases.map { ($0.rawValue, $0.displayName) }
    public var synthGenreID: String {
        get { synthGenre.rawValue }
        set { synthGenre = MusicGenre(rawValue: newValue) ?? .auto }
    }

    public func generateMatchingSynth(style: SynthStyle) {
        let genre = synthGenre
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
            let r = AppModel.makeSynthPart(style: style, guitar: load(src.guitar), bass: load(src.bass), tempo: tempo, beatsPerBar: bpb, genre: genre)
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
