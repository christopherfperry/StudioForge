import Foundation
import SFCore
import SFEffects
import SFInstruments
import SFProject

/// The real-time mixer. `render` is called from the audio I/O thread (or the offline renderer)
/// and follows strict real-time rules: no allocation, no locks, no I/O, no Objective-C messaging.
/// Structure arrives via `graphSwap`, recordings via `recordSwap`, live MIDI via SPSC queues.
public final class EngineCore: @unchecked Sendable {
    public static let maxInputChannels = 64

    public let sampleRate: Double
    public let maxFrames: Int
    public let transport = Transport()
    public let graphSwap = RTObjectSwap<RenderGraph>()
    public let recordSwap = RTObjectSwap<RecordSession>()

    /// MIDI from CoreMIDI (producer: MIDI thread) and from the on-screen keyboard (producer: main thread).
    public let midiQueue = SPSCQueue<LiveMIDIEvent>(capacity: 1024, filler: .empty)
    public let uiMIDIQueue = SPSCQueue<LiveMIDIEvent>(capacity: 512, filler: .empty)
    /// Index (in the current graph) of the track receiving live MIDI; -1 = none.
    public let liveMIDITarget = AtomicInt(-1)
    private var lastLiveTarget = -1

    public let masterVolume = AtomicFloat(1)
    public let masterPeakL = AtomicFloat(0)
    public let masterPeakR = AtomicFloat(0)
    public let inputPeaks: [AtomicFloat] = (0..<EngineCore.maxInputChannels).map { _ in AtomicFloat(0) }
    /// Smoothed DSP load: render time / buffer duration (0...1+).
    public let cpuLoad = AtomicFloat(0)
    public let overloads = AtomicInt(0)
    public let metronomeEnabledForOffline = AtomicBool(true)

    /// Input channel buffers the I/O layer fills before calling `render`.
    public let inputBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let silence: UnsafeMutablePointer<Float>
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>

    // Metronome state (audio thread only).
    private var clickRemaining = 0
    private var clickPhase: Float = 0
    private var clickInc: Float = 0
    private var clickAmp: Float = 0
    private var clickDecay: Float = 0.999
    private var wasPlaying = false

    public init(sampleRate: Double, maxFrames: Int = 4096) {
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        inputBuffers = .allocate(capacity: EngineCore.maxInputChannels)
        for i in 0..<EngineCore.maxInputChannels {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            p.initialize(repeating: 0, count: maxFrames)
            (inputBuffers + i).initialize(to: p)
        }
        silence = .allocate(capacity: maxFrames); silence.initialize(repeating: 0, count: maxFrames)
        scratchL = .allocate(capacity: maxFrames); scratchL.initialize(repeating: 0, count: maxFrames)
        scratchR = .allocate(capacity: maxFrames); scratchR.initialize(repeating: 0, count: maxFrames)
    }

    deinit {
        for i in 0..<EngineCore.maxInputChannels { inputBuffers[i].deallocate() }
        inputBuffers.deallocate()
        silence.deallocate(); scratchL.deallocate(); scratchR.deallocate()
    }

    @inline(__always) private func input(_ ch: Int, count: Int) -> UnsafeMutablePointer<Float> {
        ch >= 0 && ch < count && ch < EngineCore.maxInputChannels ? inputBuffers[ch] : silence
    }

    // MARK: - Render

    /// Renders `frames` (<= maxFrames) stereo frames. `inputChannelCount` channels of
    /// `inputBuffers` hold this cycle's hardware input.
    public func render(inputChannelCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard frames > 0 else { return }
        guard frames <= maxFrames, let graph = graphSwap.acquire(), frames <= graph.maxFrames else {
            left.update(repeating: 0, count: frames); right.update(repeating: 0, count: frames)
            return
        }
        let record = recordSwap.acquire()
        let inCount = min(inputChannelCount, EngineCore.maxInputChannels)
        for ch in 0..<inCount { inputPeaks[ch].storeMax(BufferOps.peak(inputBuffers[ch], frames)) }

        let playing = transport.isPlaying.value
        let recording = playing && transport.isRecording.value
        var pos = transport.position.value

        // Seek / start / stop handling.
        let seek = transport.seekRequest.exchange(Transport.noSeek)
        if seek != Transport.noSeek {
            pos = seek
            for n in graph.tracks { n.locate(pos); n.instrument?.allNotesOff(hard: false) }
            clickRemaining = 0
        }
        if playing && !wasPlaying {
            for n in graph.tracks { n.locate(pos) }
        } else if !playing && wasPlaying {
            for n in graph.tracks where !n.events.isEmpty { n.instrument?.allNotesOff(hard: false) }
        }
        wasPlaying = playing
        HostContext.shared.isPlaying.value = playing

        dispatchLiveMIDI(graph)

        graph.mixL.clear(frames); graph.mixR.clear(frames)

        // Split the block at the loop end (loop is ignored while recording).
        var offset = 0
        while offset < frames {
            var m = frames - offset
            var wrapTo: Int?
            if playing && !recording && transport.loopEnabled.value {
                let ls = transport.loopStart.value, le = transport.loopEnd.value
                if le > ls + 64, pos < le, pos + m >= le {
                    m = le - pos
                    wrapTo = ls
                }
            }
            if m > 0 {
                renderSegment(graph, record: recording ? record : nil, inCount: inCount, offset: offset, count: m,
                              position: pos, playing: playing)
            }
            offset += m
            if playing { pos += m }
            if let w = wrapTo {
                pos = w
                for n in graph.tracks { n.locate(pos); if !n.events.isEmpty { n.instrument?.allNotesOff(hard: false) } }
            }
        }

        // Master bus.
        let ml = graph.mixL.data, mr = graph.mixR.data
        graph.masterChain.process(left: ml, right: mr, frameCount: frames)
        let target = masterVolume.value
        let start = graph.lastMasterGain
        let step = (target - start) / Float(frames)
        for i in 0..<frames {
            let g = start + step * Float(i + 1)
            left[i] = ml[i] * g
            right[i] = mr[i] * g
        }
        graph.lastMasterGain = target
        masterPeakL.storeMax(BufferOps.peak(left, frames))
        masterPeakR.storeMax(BufferOps.peak(right, frames))

        // Metronome is added after the master bus (never printed into bounces through master FX).
        if transport.metronomeEnabled.value && metronomeEnabledForOffline.value && playing &&
            (!transport.metronomeOnlyWhileRecording.value || recording) {
            renderClick(left: left, right: right, frames: frames, startPos: transport.position.value, seekPos: seek)
        } else {
            clickRemaining = 0
        }
        // Soft safety clip to protect speakers from runaway feedback.
        for i in 0..<frames {
            if left[i] > 4 || left[i] < -4 { left[i] = left[i] > 0 ? 4 : -4 }
            if right[i] > 4 || right[i] < -4 { right[i] = right[i] > 0 ? 4 : -4 }
        }

        if playing { transport.position.value = pos }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e9
        let budget = Double(frames) / sampleRate
        let load = Float(elapsed / budget)
        if load > 1 { overloads.add(1) }
        let prev = cpuLoad.value
        cpuLoad.value = prev + (load - prev) * (load > prev ? 0.5 : 0.05)
    }

    private func dispatchLiveMIDI(_ graph: RenderGraph) {
        let target = liveMIDITarget.value
        if target != lastLiveTarget {
            if lastLiveTarget >= 0 && lastLiveTarget < graph.tracks.count { graph.tracks[lastLiveTarget].instrument?.allNotesOff(hard: false) }
            lastLiveTarget = target
        }
        let inst: Instrument? = target >= 0 && target < graph.tracks.count ? graph.tracks[target].instrument : nil
        while let e = midiQueue.pop() { apply(e, to: inst) }
        while let e = uiMIDIQueue.pop() { apply(e, to: inst) }
    }

    @inline(__always) private func apply(_ e: LiveMIDIEvent, to inst: Instrument?) {
        guard let inst else { return }
        switch e.kind {
        case .noteOn:
            if e.data2 == 0 { inst.noteOff(note: Int(e.data1)) } else { inst.noteOn(note: Int(e.data1), velocity: Float(e.data2) / 127) }
        case .noteOff: inst.noteOff(note: Int(e.data1))
        case .pitchBend: inst.pitchBend(semitones: e.value)
        case .controlChange: inst.controlChange(Int(e.data1), value: Float(e.data2) / 127)
        case .allNotesOff: inst.allNotesOff(hard: false)
        }
    }

    private func renderSegment(_ graph: RenderGraph, record: RecordSession?, inCount: Int, offset: Int, count m: Int,
                               position p: Int, playing: Bool) {
        var anySolo = false
        for n in graph.tracks where n.controls.solo.value { anySolo = true; break }
        let direct = transport.directMonitoring.value

        // Capture window intersection for this segment.
        var capS = 0, capE = 0
        if let r = record {
            var cs = r.captureStart, ce = r.captureEnd
            if transport.punchEnabled.value {
                cs = max(cs, transport.punchStart.value); ce = min(ce, transport.punchEnd.value)
            }
            capS = max(p, cs); capE = min(p + m, ce)
        }

        for node in graph.tracks {
            let c = node.controls
            let L = node.bufL.data + offset, R = node.bufR.data + offset

            // 1. Sources: instrument (with sample-accurate timeline notes) or silence.
            if let inst = node.instrument {
                var done = 0
                if playing {
                    let ev = node.events
                    while node.cursor < ev.count && ev[node.cursor].frame < p + m {
                        let e = ev[node.cursor]
                        let at = max(0, min(m, e.frame - p))
                        if at > done { inst.render(left: L + done, right: R + done, frameCount: at - done); done = at }
                        if e.velocity > 0 { inst.noteOn(note: e.note, velocity: e.velocity) } else { inst.noteOff(note: e.note) }
                        node.cursor += 1
                    }
                }
                if done < m { inst.render(left: L + done, right: R + done, frameCount: m - done) }
            } else {
                L.update(repeating: 0, count: m); R.update(repeating: 0, count: m)
            }

            // 2. Audio clips.
            if playing {
                for clip in node.clips {
                    if clip.start >= p + m { break }
                    if clip.end <= p { continue }
                    let s = max(p, clip.start), e = min(p + m, clip.end)
                    let b = clip.buffer
                    for f in s..<e {
                        let rel = f - clip.start
                        let src = rel + clip.sourceOffset
                        if src < 0 || src >= b.frames { continue }
                        let g = clip.gain * clip.fade(rel)
                        L[f - p] += b.left[src] * g
                        R[f - p] += b.right[src] * g
                    }
                }
            }

            // 3. Input: record the dry signal (always), monitor in software if requested.
            let isAudio = node.kind == .audio
            let armed = c.arm.value
            let inFirst = c.inputFirst.value
            let stereoIn = c.inputCount.value == 2
            let inL = input(inFirst, count: inCount) + offset
            let inR = (stereoIn ? input(inFirst + 1, count: inCount) : input(inFirst, count: inCount)) + offset
            var lane: RecordSession.Lane?
            if armed, isAudio, capE > capS, let r = record, let l = r.lane(for: node.id) {
                lane = l
                let o = capS - p, n = capE - capS
                if l.firstFrame.value == Int.min { l.firstFrame.value = capS }
                let written: Int
                if l.channels == 2 { written = l.dry.writeInterleaved(left: inL + o, right: inR + o, count: n) }
                else { written = l.dry.write(inL + o, count: n) }
                if written < n { l.overflow.value = true }
                l.framesCaptured.add(n)
            }
            let mon = c.monitor.value
            let monitoring = isAudio && !direct && (mon == 2 || (mon == 1 && armed))
            if monitoring && inCount > 0 {
                for i in 0..<m { L[i] += inL[i]; R[i] += inR[i] }
            }

            // 4. Insert chain.
            node.chain.process(left: L, right: R, frameCount: m)

            if let l = lane, let wet = l.wet {
                let o = capS - p, n = capE - capS
                if wet.writeInterleaved(left: L + o, right: R + o, count: n) < n { l.overflow.value = true }
            }

            // 5. Delay compensation (skipped while live-monitoring to keep monitoring latency minimal).
            if node.pdcDelay > 0, !monitoring, let dl = node.delayL, let dr = node.delayR {
                let d = node.pdcDelay
                for i in 0..<m {
                    dl.write(L[i]); dr.write(R[i])
                    L[i] = dl.read(d); R[i] = dr.read(d)
                }
            }

            // 6. Fader, pan (constant-power, 0 dB at centre), mute/solo.
            let (gl, gr) = c.targetGains(anySolo: anySolo)
            let sl = node.lastGainL, sr = node.lastGainR
            let dl = (gl - sl) / Float(m), dr = (gr - sr) / Float(m)
            var pkL: Float = 0, pkR: Float = 0
            let mixL = graph.mixL.data + offset, mixR = graph.mixR.data + offset
            for i in 0..<m {
                let a = L[i] * (sl + dl * Float(i + 1))
                let b = R[i] * (sr + dr * Float(i + 1))
                mixL[i] += a; mixR[i] += b
                let aa = abs(a), bb = abs(b)
                if aa > pkL { pkL = aa }
                if bb > pkR { pkR = bb }
            }
            node.lastGainL = gl; node.lastGainR = gr
            c.peakL.storeMax(pkL); c.peakR.storeMax(pkR)
        }
    }

    private func renderClick(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                             startPos: Int, seekPos: Int) {
        // Position at the start of this block (before advancing).
        let blockStart = seekPos != Transport.noSeek ? seekPos : startPos
        let fpc = transport.framesPerClick(sampleRate: sampleRate)
        let gain = transport.metronomeGain.value
        let beatsPerBar = max(1, transport.beatsPerBar.value)
        let loopOn = transport.loopEnabled.value && !transport.isRecording.value
        let le = transport.loopEnd.value, ls = transport.loopStart.value
        var pos = blockStart
        for i in 0..<frames {
            if loopOn && le > ls + 64 && pos == le { pos = ls }
            // Click on the first frame at or after each beat boundary k * fpc.
            let k = (Double(pos) / fpc).rounded(.down)
            if Double(pos) - k * fpc < 1 {
                var idx = Int(k) % beatsPerBar
                if idx < 0 { idx += beatsPerBar }
                let accent = idx == 0 && transport.metronomeAccent.value
                clickInc = (accent ? 1760 : 1320) / Float(sampleRate)
                clickAmp = accent ? 1 : 0.7
                clickPhase = 0
                clickRemaining = Int(sampleRate * 0.035)
                clickDecay = expf(-1 / (Float(sampleRate) * 0.008))
            }
            if clickRemaining > 0 {
                let s = sinf(twoPi * clickPhase) * clickAmp * gain
                clickPhase += clickInc
                if clickPhase >= 1 { clickPhase -= 1 }
                clickAmp *= clickDecay
                clickRemaining -= 1
                left[i] += s; right[i] += s
            }
            pos += 1
        }
    }

    // MARK: - Helpers (main thread)

    /// Takes and resets the meter peaks (call from a UI timer).
    public func readMeters(trackControls: [TrackControls]) -> (master: (Float, Float), tracks: [(Float, Float)]) {
        let m = (masterPeakL.exchange(0), masterPeakR.exchange(0))
        return (m, trackControls.map { ($0.peakL.exchange(0), $0.peakR.exchange(0)) })
    }
}
