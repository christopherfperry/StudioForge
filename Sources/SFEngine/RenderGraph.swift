import Foundation
import SFCore
import SFEffects
import SFInstruments
import SFProject

/// Per-track live controls. These objects survive graph rebuilds (keyed by track id) so fader
/// moves never need a rebuild and meters keep working while the structure changes.
public final class TrackControls: @unchecked Sendable {
    public let volume = AtomicFloat(1)          // linear gain
    public let pan = AtomicFloat(0)             // -1...1
    public let mute = AtomicBool(false)
    public let solo = AtomicBool(false)
    public let arm = AtomicBool(false)
    public let monitor = AtomicInt(1)           // 0 off, 1 auto, 2 on
    public let captureWet = AtomicBool(false)
    public let inputFirst = AtomicInt(0)
    public let inputCount = AtomicInt(1)
    public let peakL = AtomicFloat(0)
    public let peakR = AtomicFloat(0)
    public init() {}

    public func update(from t: Track) {
        volume.value = dbToGain(t.volumeDB)
        pan.value = clampf(t.pan, -1, 1)
        mute.value = t.mute
        solo.value = t.solo
        arm.value = t.arm
        monitor.value = t.monitor == .off ? 0 : (t.monitor == .auto ? 1 : 2)
        captureWet.value = t.captureWet
        inputFirst.value = max(0, t.input.firstChannel)
        inputCount.value = t.input.channelCount == 2 ? 2 : 1
    }

    /// Target fader gains (left, right): constant-power pan, 0 dB at centre, zero when muted or
    /// silenced by another track's solo. Shared by the live engine and offline bounces.
    @inline(__always) public func targetGains(anySolo: Bool) -> (Float, Float) {
        guard !mute.value && (!anySolo || solo.value) else { return (0, 0) }
        let v = volume.value
        let angle = (pan.value + 1) * Float.pi / 4
        let gl = v * cosf(angle) * Float(2).squareRoot()
        let gr = v * sinf(angle) * Float(2).squareRoot()
        return (min(gl, v), min(gr, v)) // never boost a side above the fader gain
    }
}

/// One audio region prepared for rendering (frames at engine rate).
struct ClipRender {
    var start: Int
    var end: Int
    var sourceOffset: Int
    var gain: Float
    var fadeIn: Int
    var fadeOut: Int
    var shape: FadeShape
    var buffer: SampleBuffer

    @inline(__always) func fade(_ rel: Int) -> Float {
        var g: Float = 1
        if fadeIn > 0, rel < fadeIn { g *= shape.gain(Float(rel) / Float(fadeIn)) }
        let len = end - start
        if fadeOut > 0, rel > len - fadeOut { g *= shape.gain(Float(len - rel) / Float(fadeOut)) }
        return g
    }
}

/// Note event on the timeline (absolute frames). velocity 0 = note off.
struct TimedNote {
    var frame: Int
    var note: Int
    var velocity: Float
}

/// Render-side track: everything the audio thread needs, pre-allocated.
final class TrackNode {
    let id: UUID
    let kind: TrackKind
    let controls: TrackControls
    let chain: EffectChain
    let instrument: Instrument?
    let clips: [ClipRender]
    let events: [TimedNote]
    var cursor = 0
    let latency: Int
    var pdcDelay = 0
    let delayL: DelayLine?
    let delayR: DelayLine?
    let bufL: ScratchBuffer
    let bufR: ScratchBuffer
    var lastGainL: Float = 0
    var lastGainR: Float = 0
    var notesHeld = false

    init(id: UUID, kind: TrackKind, controls: TrackControls, chain: EffectChain, instrument: Instrument?,
         clips: [ClipRender], events: [TimedNote], pdcDelay: Int, maxFrames: Int) {
        self.id = id; self.kind = kind; self.controls = controls; self.chain = chain
        self.instrument = instrument; self.clips = clips; self.events = events
        latency = chain.latencySamples
        self.pdcDelay = pdcDelay
        delayL = pdcDelay > 0 ? DelayLine(maxDelaySamples: pdcDelay + 8) : nil
        delayR = pdcDelay > 0 ? DelayLine(maxDelaySamples: pdcDelay + 8) : nil
        bufL = ScratchBuffer(capacity: maxFrames)
        bufR = ScratchBuffer(capacity: maxFrames)
    }

    /// Positions the event cursor at the first event at or after `frame` (binary search, RT safe).
    func locate(_ frame: Int) {
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if events[mid].frame < frame { lo = mid + 1 } else { hi = mid }
        }
        cursor = lo
    }
}

/// Immutable snapshot of the mix structure handed to the audio thread via RTObjectSwap.
public final class RenderGraph {
    public let sampleRate: Double
    public let maxFrames: Int
    let tracks: [TrackNode]
    public let masterChain: EffectChain
    let mixL: ScratchBuffer
    let mixR: ScratchBuffer
    public let maxLatency: Int
    public let trackIDs: [UUID]
    /// Clips that could not be rendered yet (still loading / failed), for UI display.
    public let pendingClipCount: Int
    var lastMasterGain: Float = 1

    init(sampleRate: Double, maxFrames: Int, tracks: [TrackNode], masterChain: EffectChain, pendingClips: Int) {
        self.sampleRate = sampleRate; self.maxFrames = maxFrames; self.tracks = tracks
        self.masterChain = masterChain
        mixL = ScratchBuffer(capacity: maxFrames); mixR = ScratchBuffer(capacity: maxFrames)
        maxLatency = tracks.map(\.latency).max() ?? 0
        trackIDs = tracks.map(\.id)
        pendingClipCount = pendingClips
    }

    /// Live effect instance for UI parameter editing (main thread).
    public func effect(track: UUID, slot: UUID) -> AudioEffect? {
        tracks.first { $0.id == track }?.chain.slots.first { $0.id == slot }?.effect
    }
    public func slot(track: UUID, slot: UUID) -> EffectSlot? {
        tracks.first { $0.id == track }?.chain.slots.first { $0.id == slot }
    }
    public func masterSlot(_ slot: UUID) -> EffectSlot? { masterChain.slots.first { $0.id == slot } }
    public func instrument(track: UUID) -> Instrument? { tracks.first { $0.id == track }?.instrument }
    public func index(of track: UUID) -> Int? { trackIDs.firstIndex(of: track) }
}

/// Builds render graphs from a project. Reuses effect slots / instruments of the previous graph
/// when ids and types match, so rebuilding (e.g. after moving a clip) keeps reverb tails and
/// synth voices alive and avoids expensive IR re-synthesis.
public struct GraphBuilder {
    public var sampleRate: Double
    public var maxFrames: Int
    public var packageURL: URL?
    /// Render only these tracks (stem bounce); nil = all.
    public var onlyTracks: Set<UUID>?
    public var includeMasterChain = true

    public init(sampleRate: Double, maxFrames: Int, packageURL: URL?) {
        self.sampleRate = sampleRate; self.maxFrames = maxFrames; self.packageURL = packageURL
    }

    public enum BufferMode { case cached, synchronous }

    func build(project: Project, controls: (UUID) -> TrackControls, cache: ClipAudioCache,
               mode: BufferMode, previous: RenderGraph?) -> RenderGraph {
        let reuse = previous.flatMap { $0.sampleRate == sampleRate && $0.maxFrames == maxFrames ? $0 : nil }
        var pending = 0
        var nodes: [TrackNode] = []
        let spb = project.secondsPerBeat
        for track in project.tracks {
            if let only = onlyTracks, !only.contains(track.id) { continue }
            let old = reuse?.tracks.first { $0.id == track.id }
            let chain = makeChain(track.effects, old: old?.chain)
            var instrument: Instrument?
            if track.kind != .audio, let st = track.instrument {
                if let oi = old?.instrument, oi.typeID == st.type, oi.extras == st.extra {
                    oi.parameters.apply(st.params)
                    instrument = oi
                } else if let ni = InstrumentRegistry.shared.make(from: st) {
                    ni.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
                    instrument = ni
                }
            }
            var clips: [ClipRender] = []
            for c in track.audioClips where !c.muted && c.duration > 0 {
                let url = ProjectPackage.resolve(c.file, in: packageURL)
                let buf: SampleBuffer?
                switch mode {
                case .cached: buf = cache.buffer(for: url)
                case .synchronous: buf = try? cache.loadSync(url)
                }
                guard let b = buf else { pending += 1; continue }
                let start = Int((c.start * sampleRate).rounded())
                let len = Int((c.duration * sampleRate).rounded())
                clips.append(ClipRender(start: start, end: start + len, sourceOffset: Int((c.offset * sampleRate).rounded()),
                                        gain: dbToGain(c.gainDB), fadeIn: Int(c.fadeIn * sampleRate),
                                        fadeOut: Int(c.fadeOut * sampleRate), shape: c.fadeShape, buffer: b))
            }
            clips.sort { $0.start < $1.start }
            var events: [TimedNote] = []
            if instrument != nil {
                for m in track.midiClips where !m.muted {
                    let clipEnd = m.startBeat + m.lengthBeats
                    for n in m.notes where n.startBeat < m.lengthBeats && n.startBeat >= 0 {
                        let on = m.startBeat + n.startBeat
                        let off = min(clipEnd, on + max(0.01, n.durationBeats))
                        let onF = Int((on * spb * sampleRate).rounded())
                        let offF = max(onF + 1, Int((off * spb * sampleRate).rounded()))
                        events.append(TimedNote(frame: onF, note: n.pitch, velocity: Float(max(1, min(127, n.velocity))) / 127))
                        events.append(TimedNote(frame: offF, note: n.pitch, velocity: 0))
                    }
                }
                // Note-offs before note-ons at the same frame so re-struck notes retrigger.
                events.sort { $0.frame != $1.frame ? $0.frame < $1.frame : $0.velocity < $1.velocity }
            }
            nodes.append(TrackNode(id: track.id, kind: track.kind, controls: controls(track.id), chain: chain,
                                   instrument: instrument, clips: clips, events: events, pdcDelay: 0, maxFrames: maxFrames))
        }
        // Plugin-delay compensation: delay every track to the worst chain latency.
        let maxLat = nodes.map(\.latency).max() ?? 0
        if maxLat > 0 {
            nodes = nodes.map { n in
                let d = maxLat - n.latency
                guard d > 0 else { return n }
                return TrackNode(id: n.id, kind: n.kind, controls: n.controls, chain: n.chain, instrument: n.instrument,
                                 clips: n.clips, events: n.events, pdcDelay: d, maxFrames: maxFrames)
            }
        }
        let master = includeMasterChain ? makeChain(project.master.effects, old: reuse?.masterChain) : EffectChain(slots: [], maxFrames: maxFrames)
        let graph = RenderGraph(sampleRate: sampleRate, maxFrames: maxFrames, tracks: nodes, masterChain: master, pendingClips: pending)
        // Carry smoothing state so a rebuild doesn't produce a gain jump.
        if let r = reuse {
            graph.lastMasterGain = r.lastMasterGain
            for n in nodes { if let o = r.tracks.first(where: { $0.id == n.id }) { n.lastGainL = o.lastGainL; n.lastGainR = o.lastGainR } }
        }
        return graph
    }

    private func makeChain(_ states: [EffectState], old: EffectChain?) -> EffectChain {
        var slots: [EffectSlot] = []
        for s in states {
            // Hosted Audio Units keep their own state blob in extras, so only the component identity matters.
            if let o = old?.slots.first(where: { $0.id == s.id }), o.effect.typeID == s.type,
               s.type == "au" ? o.effect.extras["component"] == s.extra["component"] : o.effect.extras == s.extra {
                o.effect.parameters.apply(s.params)
                o.effect.parametersChangedOffline()
                o.bypass.value = s.bypassed
                o.mix.value = s.mix
                slots.append(o)
                continue
            }
            guard let fx = EffectRegistry.shared.make(from: s) else {
                print("[Fitzrovia Records DAW] Unknown effect type '\(s.type)' skipped")
                continue
            }
            fx.prepare(sampleRate: sampleRate, maxFrames: maxFrames)
            slots.append(EffectSlot(id: s.id, effect: fx, bypassed: s.bypassed, mix: s.mix, maxFrames: maxFrames))
        }
        return EffectChain(slots: slots, maxFrames: maxFrames)
    }
}
