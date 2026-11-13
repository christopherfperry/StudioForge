import Foundation
import SFCore
import SFEffects
import SFInstruments
import SFProject

/// Faster-than-real-time bounce of the project (master mix or individual stems) using the same
/// EngineCore as live playback, with fresh effect/instrument instances so live state is untouched.
public struct OfflineRenderer {
    public struct Options {
        public var sampleRate: Double = 48_000
        public var start: Double = 0
        /// nil = project content end.
        public var end: Double?
        /// Extra seconds rendered after `end` so reverb/delay tails ring out.
        public var tail: Double = 2
        public var includeMasterChain = true
        /// Respect mute/solo states (master bounce). Stems ignore mute/solo.
        public var respectMuteSolo = true
        public var blockSize = 1024
        public init() {}
    }

    public typealias Progress = (Double) -> Void

    public init() {}

    /// Renders the master mix.
    public func renderMaster(project: Project, packageURL: URL?, options: Options = Options(),
                             progress: Progress? = nil, isCancelled: () -> Bool = { false }) throws -> AudioData {
        try render(project: project, packageURL: packageURL, only: nil, options: options, progress: progress, isCancelled: isCancelled)
    }

    /// Renders each track on its own (post-fader, post-insert; master chain optional).
    public func renderStems(project: Project, packageURL: URL?, options: Options = Options(),
                            progress: Progress? = nil, isCancelled: () -> Bool = { false }) throws -> [(track: Track, audio: AudioData)] {
        var out: [(Track, AudioData)] = []
        let n = max(1, project.tracks.count)
        for (i, t) in project.tracks.enumerated() {
            var o = options
            o.respectMuteSolo = false
            let a = try render(project: project, packageURL: packageURL, only: [t.id], options: o,
                               progress: { p in progress?((Double(i) + p) / Double(n)) }, isCancelled: isCancelled)
            out.append((t, a))
        }
        return out
    }

    func render(project: Project, packageURL: URL?, only: Set<UUID>?, options: Options,
                progress: Progress?, isCancelled: () -> Bool) throws -> AudioData {
        let sr = options.sampleRate
        let block = max(64, min(4096, options.blockSize))
        let core = EngineCore(sampleRate: sr, maxFrames: block)
        core.metronomeEnabledForOffline.value = false
        let cache = ClipAudioCache(sampleRate: sr)
        var builder = GraphBuilder(sampleRate: sr, maxFrames: block, packageURL: packageURL)
        builder.onlyTracks = only
        builder.includeMasterChain = options.includeMasterChain
        var controls: [UUID: TrackControls] = [:]
        for t in project.tracks {
            let c = TrackControls()
            c.update(from: t)
            c.arm.value = false
            if !options.respectMuteSolo { c.mute.value = false; c.solo.value = false }
            controls[t.id] = c
        }
        let graph = builder.build(project: project, controls: { controls[$0] ?? TrackControls() }, cache: cache,
                                  mode: .synchronous, previous: nil)
        // Start smoothing at the exact target gains (pan, mute and solo included) so the first block
        // of a bounce doesn't leak non-soloed tracks or ramp the pan.
        let anySolo = graph.tracks.contains { $0.controls.solo.value }
        for n in graph.tracks {
            (n.lastGainL, n.lastGainR) = n.controls.targetGains(anySolo: anySolo)
        }
        core.masterVolume.value = dbToGain(project.master.volumeDB)
        graph.lastMasterGain = core.masterVolume.value
        core.graphSwap.publish(graph)

        let endSec = options.end ?? project.contentEnd
        let startFrame = Int(options.start * sr)
        let endFrame = max(startFrame + 1, Int((endSec + max(0, options.tail)) * sr))
        let total = endFrame - startFrame
        core.transport.loopEnabled.value = false
        core.transport.seek(toFrame: startFrame)
        core.transport.isPlaying.value = true

        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        var done = 0
        var lastReport = 0
        try left.withUnsafeMutableBufferPointer { lb in
            try right.withUnsafeMutableBufferPointer { rb in
                while done < total {
                    if isCancelled() { throw StudioForgeError.cancelled }
                    let n = min(block, total - done)
                    core.render(inputChannelCount: 0, left: lb.baseAddress! + done, right: rb.baseAddress! + done, frames: n)
                    done += n
                    if done - lastReport > Int(sr) { lastReport = done; progress?(Double(done) / Double(total)) }
                }
            }
        }
        progress?(1)
        core.transport.isPlaying.value = false
        return AudioData(channels: [left, right], sampleRate: sr)
    }
}
