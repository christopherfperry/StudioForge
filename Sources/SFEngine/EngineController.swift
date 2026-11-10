import Foundation
import SFCore
import SFEffects
import SFInstruments
import SFProject

/// Abstraction over the hardware I/O layer (CoreAudio on macOS, a null driver elsewhere / in tests).
public protocol AudioIODriver: AnyObject {
    var isRunning: Bool { get }
    /// Valid after `open()`.
    var sampleRate: Double { get }
    var bufferFrames: Int { get }
    var inputChannelCount: Int { get }
    var inputLatencyFrames: Int { get }
    var outputLatencyFrames: Int { get }
    var statusMessage: String { get }
    /// Opens/configures devices (non-real-time). After this `sampleRate` is known.
    func open() throws
    /// Starts calling `core.render` from the I/O thread.
    func start(core: EngineCore) throws
    func stop()
}

/// Driver that produces no audio (Linux builds, unit tests, or when no device is available).
public final class NullAudioIO: AudioIODriver {
    public private(set) var isRunning = false
    public var sampleRate: Double
    public var bufferFrames = 256
    public var inputChannelCount = 0
    public var inputLatencyFrames = 0
    public var outputLatencyFrames = 0
    public var statusMessage = "No audio device"
    public init(sampleRate: Double = 48_000) { self.sampleRate = sampleRate }
    public func open() throws {}
    public func start(core: EngineCore) throws { isRunning = true }
    public func stop() { isRunning = false }
}

/// Main-thread façade over the engine: owns the EngineCore, graph rebuilding, live control sync,
/// transport commands and recording. The UI layer wraps this in an ObservableObject.
public final class EngineController {
    public private(set) var core: EngineCore
    public let io: AudioIODriver
    public let clipCache: ClipAudioCache
    public let recorder = Recorder()

    public private(set) var project = Project()
    public private(set) var packageURL: URL?
    private var controls: [UUID: TrackControls] = [:]
    private var structureKey: Project?
    public var selectedTrackID: UUID? { didSet { updateLiveMIDITarget() } }
    /// Manual record offset (frames) added to automatic latency compensation (positive = earlier).
    public var recordOffsetFrames = 0
    public private(set) var lastError: String?
    /// Called (main queue) when clip audio finished loading and the graph was rebuilt.
    public var onGraphRebuilt: (() -> Void)?

    public init(io: AudioIODriver, maxFrames: Int = 4096) {
        self.io = io
        core = EngineCore(sampleRate: io.sampleRate, maxFrames: maxFrames)
        clipCache = ClipAudioCache(sampleRate: io.sampleRate)
        clipCache.onLoaded = { [weak self] in self?.rebuildGraph(); self?.onGraphRebuilt?() }
    }

    // MARK: Audio device lifecycle

    /// Opens the device, (re)creates the core for its sample rate and starts processing.
    public func startAudio() {
        do {
            if io.isRunning { io.stop() }
            try io.open()
            if io.sampleRate != core.sampleRate {
                let t = core.transport
                let pos = Double(t.position.value) / core.sampleRate
                core = EngineCore(sampleRate: io.sampleRate, maxFrames: core.maxFrames)
                clipCache.setSampleRate(io.sampleRate)
                applyTransportSettings()
                core.transport.seek(toFrame: Int(pos * io.sampleRate))
                structureKey = nil
                rebuildGraph()
            }
            try io.start(core: core)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stopAudio() { io.stop() }

    public var sampleRate: Double { core.sampleRate }

    /// Round-trip latency in frames (input + output + buffer as reported by the driver).
    public var roundTripLatencyFrames: Int { io.inputLatencyFrames + io.outputLatencyFrames }
    public var latencyDescription: String {
        let sr = max(1, core.sampleRate)
        let inMs = Double(io.inputLatencyFrames) / sr * 1000, outMs = Double(io.outputLatencyFrames) / sr * 1000
        return String(format: "Buffer %d · In %.1f ms · Out %.1f ms · Round trip %.1f ms", io.bufferFrames, inMs, outMs, inMs + outMs)
    }

    // MARK: Project sync

    /// Loads a project (rebuilds everything).
    public func load(project: Project, packageURL: URL?) {
        self.packageURL = packageURL
        self.project = project
        structureKey = nil
        controls = controls.filter { id, _ in project.tracks.contains { $0.id == id } }
        sync(project)
    }

    public func setPackageURL(_ url: URL?) {
        guard url != packageURL else { return }
        packageURL = url
        structureKey = nil
        rebuildGraph()
    }

    /// Call after every document change. Cheap when only live values changed (faders, knobs,
    /// bypass); rebuilds the render graph only when structure changed.
    public func update(project: Project) {
        self.project = project
        sync(project)
    }

    private func sync(_ p: Project) {
        for t in p.tracks { controls(for: t.id).update(from: t) }
        core.masterVolume.value = dbToGain(p.master.volumeDB)
        applyTransportSettings()
        let key = Self.structure(of: p)
        if key != structureKey {
            structureKey = key
            rebuildGraph()
        } else {
            pushLiveValues(p)
        }
        updateLiveMIDITarget()
    }

    private func controls(for id: UUID) -> TrackControls {
        if let c = controls[id] { return c }
        let c = TrackControls()
        controls[id] = c
        return c
    }

    public func trackControls(_ id: UUID) -> TrackControls? { controls[id] }

    private func applyTransportSettings() {
        var s = SFProjectTransportSettings()
        s.tempo = project.tempo
        s.beatsPerBar = project.timeSignature.numerator
        s.beatUnit = project.timeSignature.denominator
        s.loopEnabled = project.loop.enabled && project.loop.isValid
        s.loopStart = project.loop.start; s.loopEnd = project.loop.end
        s.punchEnabled = project.punch.enabled && project.punch.isValid
        s.punchStart = project.punch.start; s.punchEnd = project.punch.end
        s.metronomeEnabled = project.metronome.enabled
        s.metronomeOnlyWhileRecording = project.metronome.onlyWhileRecording
        s.metronomeDB = project.metronome.volumeDB
        s.metronomeAccent = project.metronome.accentFirstBeat
        core.transport.apply(project: s, sampleRate: core.sampleRate)
    }

    /// Rebuilds and publishes the render graph from the current project.
    public func rebuildGraph() {
        let builder = GraphBuilder(sampleRate: core.sampleRate, maxFrames: core.maxFrames, packageURL: packageURL)
        let graph = builder.build(project: project, controls: { [unowned self] in self.controls(for: $0) },
                                  cache: clipCache, mode: .cached, previous: core.graphSwap.latest)
        core.graphSwap.publish(graph)
        var urls = Set<URL>()
        for t in project.tracks { for c in t.audioClips { urls.insert(ProjectPackage.resolve(c.file, in: packageURL)) } }
        clipCache.purge(keeping: urls)
        updateLiveMIDITarget()
    }

    public var graph: RenderGraph? { core.graphSwap.latest }

    /// Pushes parameter / bypass / mix values to the live instances (no rebuild).
    private func pushLiveValues(_ p: Project) {
        guard let g = graph else { return }
        for t in p.tracks {
            for e in t.effects {
                guard let slot = g.slot(track: t.id, slot: e.id) else { continue }
                slot.bypass.value = e.bypassed
                slot.mix.value = e.mix
                if !e.params.isEmpty, slot.effect.parameters.snapshot() != e.params {
                    slot.effect.parameters.apply(e.params)
                    slot.effect.parametersChangedOffline()
                }
            }
            if let st = t.instrument, let inst = g.instrument(track: t.id) { inst.parameters.apply(st.params) }
        }
        for e in p.master.effects {
            guard let slot = g.masterSlot(e.id) else { continue }
            slot.bypass.value = e.bypassed
            slot.mix.value = e.mix
            if !e.params.isEmpty, slot.effect.parameters.snapshot() != e.params {
                slot.effect.parameters.apply(e.params)
                slot.effect.parametersChangedOffline()
            }
        }
        if g.tracks.contains(where: { $0.latency != $0.chain.latencySamples }) {
            // A bypass toggle changed plugin latency: rebuild so delay compensation stays aligned.
            rebuildGraph()
        }
    }

    /// Project copy with all live-only values normalised: equal keys ⇒ no graph rebuild needed.
    static func structure(of p: Project) -> Project {
        var s = Project(name: "", tempo: p.tempo, timeSignature: p.timeSignature, sampleRate: 0, tracks: [])
        s.id = p.id
        s.createdAt = .distantPast; s.modifiedAt = .distantPast
        s.tracks = p.tracks.map { t in
            var n = Track(name: "", kind: t.kind)
            n.id = t.id
            n.effects = t.effects.map { EffectState(id: $0.id, type: $0.type, bypassed: false, mix: 1, params: [:], extra: $0.type == "au" ? ["component": $0.extra["component"] ?? ""] : $0.extra) }
            n.instrument = t.instrument.map { InstrumentState(type: $0.type, params: [:], extra: $0.extra) }
            n.audioClips = t.audioClips
            n.midiClips = t.midiClips
            n.height = 0
            return n
        }
        s.master = MasterBus(volumeDB: 0, effects: p.master.effects.map {
            EffectState(id: $0.id, type: $0.type, params: [:], extra: $0.type == "au" ? ["component": $0.extra["component"] ?? ""] : $0.extra)
        })
        return s
    }

    // MARK: Live parameter editing (immediate, before the document round-trip)

    public func setParameter(track: UUID?, slot: UUID, id: String, value: Float) {
        let fx = track.flatMap { graph?.effect(track: $0, slot: slot) } ?? graph?.masterSlot(slot)?.effect
        fx?.parameters[id]?.value = value
        fx?.parametersChangedOffline()
    }

    public func setInstrumentParameter(track: UUID, id: String, value: Float) {
        graph?.instrument(track: track)?.parameters[id]?.value = value
    }

    public func liveEffect(track: UUID?, slot: UUID) -> AudioEffect? {
        track.flatMap { graph?.effect(track: $0, slot: slot) } ?? graph?.masterSlot(slot)?.effect
    }

    // MARK: Live MIDI

    private func updateLiveMIDITarget() {
        guard let g = graph else { core.liveMIDITarget.value = -1; return }
        var target = -1
        if let sel = selectedTrackID, let idx = g.index(of: sel), g.tracks[idx].instrument != nil { target = idx }
        if target < 0 {
            for t in project.tracks where t.arm && t.kind != .audio {
                if let idx = g.index(of: t.id), g.tracks[idx].instrument != nil { target = idx; break }
            }
        }
        core.liveMIDITarget.value = target
    }

    /// On-screen keyboard / UI note input.
    public func uiNote(_ note: Int, velocity: Int, on: Bool) {
        core.uiMIDIQueue.push(LiveMIDIEvent(kind: on ? .noteOn : .noteOff, data1: UInt8(max(0, min(127, note))),
                                            data2: UInt8(max(0, min(127, velocity)))))
    }

    // MARK: Transport

    public var isPlaying: Bool { core.transport.isPlaying.value }
    public var isRecording: Bool { core.transport.isRecording.value }
    public var positionSeconds: Double { Double(core.transport.position.value) / core.sampleRate }

    public func play() {
        guard !isPlaying else { return }
        core.transport.isPlaying.value = true
    }

    public func stop() -> [RecordedTake] {
        let wasRecording = isRecording
        core.transport.isRecording.value = false
        core.transport.isPlaying.value = false
        guard wasRecording else { return [] }
        let takes = recorder.finish()
        core.recordSwap.publish(RecordSession.empty)
        if let e = recorder.lastError { lastError = e }
        return takes
    }

    public func seek(seconds: Double) {
        core.transport.seek(toFrame: Int((seconds * core.sampleRate).rounded()))
    }

    /// Starts recording on all armed audio tracks. Count-in (metronome bars) pre-rolls before the
    /// current position; capture begins at the current position (or punch-in when punch is on).
    @discardableResult
    public func record(takeName: String? = nil) -> Bool {
        guard !isRecording else { return false }
        let armed = project.tracks.filter { $0.arm && $0.kind == .audio }
        guard !armed.isEmpty else { lastError = "Arm at least one audio track to record."; return false }
        let folder: URL
        if let pkg = packageURL { folder = pkg.appendingPathComponent(ProjectPackage.audioFolder) }
        else { folder = AppPaths.recordings }
        let sr = core.sampleRate
        let here = core.transport.position.value
        let take = takeName ?? Self.takeStamp()
        let requests = armed.map { RecordRequest(trackID: $0.id, trackName: $0.name, inputFirst: $0.input.firstChannel,
                                                 channels: $0.input.channelCount, captureWet: $0.captureWet) }
        do {
            let session = try recorder.begin(requests: requests, folder: folder, sampleRate: sr, captureStart: here,
                                             captureEnd: Int.max, takeName: take)
            core.recordSwap.publish(session)
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            return false
        }
        let countIn = project.metronome.enabled ? max(0, project.metronome.countInBars) : 0
        if countIn > 0 && !isPlaying {
            let pre = Int(Double(countIn) * project.secondsPerBar * sr)
            core.transport.seek(toFrame: here - pre)
        }
        core.transport.isRecording.value = true
        core.transport.isPlaying.value = true
        return true
    }

    static func takeStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Take \(f.string(from: Date()))"
    }

    /// Turns finished takes into clips on their tracks (latency compensated). Returns the new
    /// project; dry clips are audible, wet captures are added muted and linked to the dry clip.
    public func applyTakes(_ takes: [RecordedTake], to project: Project) -> Project {
        var p = project
        let comp = roundTripLatencyFrames + recordOffsetFrames
        for take in takes {
            guard let ti = p.trackIndex(take.trackID) else { continue }
            let file = relativePath(take.dryURL)
            var start = Double(take.startFrame - comp) / take.sampleRate
            var offset = 0.0
            var duration = Double(take.frames) / take.sampleRate
            if start < 0 { offset = -start; duration -= offset; start = 0 }
            guard duration > 0.01 else { continue }
            var dry = AudioClip(name: take.dryURL.deletingPathExtension().lastPathComponent, file: file,
                                start: start, offset: offset, duration: duration)
            dry.fadeIn = 0.003; dry.fadeOut = 0.003
            p.tracks[ti].audioClips.append(dry)
            if let w = take.wetURL {
                var wet = AudioClip(name: w.deletingPathExtension().lastPathComponent, file: relativePath(w),
                                    start: start, offset: offset, duration: duration)
                wet.isWetCapture = true
                wet.linkedDryClip = dry.id
                wet.muted = true
                p.tracks[ti].audioClips.append(wet)
            }
        }
        return p
    }

    private func relativePath(_ url: URL) -> String {
        if let pkg = packageURL, url.path.hasPrefix(pkg.path + "/") {
            return String(url.path.dropFirst(pkg.path.count + 1))
        }
        return url.path
    }

    // MARK: Meters

    public struct MeterReadout {
        public var masterL: Float, masterR: Float
        public var tracks: [UUID: (Float, Float)]
        public var cpu: Float
        public var overloads: Int
    }

    /// Reads and resets peak meters (call ~30x per second from the UI).
    public func readMeters() -> MeterReadout {
        var t: [UUID: (Float, Float)] = [:]
        for (id, c) in controls { t[id] = (c.peakL.exchange(0), c.peakR.exchange(0)) }
        return MeterReadout(masterL: core.masterPeakL.exchange(0), masterR: core.masterPeakR.exchange(0),
                            tracks: t, cpu: core.cpuLoad.value, overloads: core.overloads.value)
    }

    public func inputPeak(_ ch: Int) -> Float {
        guard ch >= 0 && ch < EngineCore.maxInputChannels else { return 0 }
        return core.inputPeaks[ch].exchange(0)
    }

    /// Releases objects retired by the audio thread (call periodically from the main thread).
    public func collectGarbage() {
        core.graphSwap.collectGarbage()
        core.recordSwap.collectGarbage()
    }
}
