import Foundation
import SFCore

/// User controls for beat generation.
public struct BeatSettings: Codable, Hashable {
    public var tempo: Double
    public var bars: Int
    /// 0 = straight, 1 = full triplet swing (applied to off-beat steps).
    public var swing: Double
    /// 0...1: timing jitter (up to ~12 ms) and velocity variation.
    public var humanize: Double
    /// 0...1: <0.3 removes ghost notes, optional '?' steps fire with this probability,
    /// >0.5 layers in the style's complexLanes.
    public var complexity: Double
    /// 0...1: probability of a fill at the end of each phrase.
    public var fills: Double
    /// Bars per phrase (fills happen on the last bar, crashes on the first).
    public var phraseLength: Int
    public var seed: UInt64

    public init(tempo: Double = 110, bars: Int = 8, swing: Double = 0, humanize: Double = 0.2,
                complexity: Double = 0.5, fills: Double = 0.5, phraseLength: Int = 4, seed: UInt64 = 1) {
        self.tempo = tempo; self.bars = bars; self.swing = swing; self.humanize = humanize
        self.complexity = complexity; self.fills = fills; self.phraseLength = phraseLength; self.seed = seed
    }
}

/// A generated drum pattern.
public struct GeneratedBeat {
    public var style: BeatStyle
    public var settings: BeatSettings
    public var notes: [MIDINote]
    public var lengthBeats: Double
}

/// Deterministic (seeded) rule-based drum pattern generator.
public struct BeatGenerator {
    public init() {}

    public func generate(style: BeatStyle, settings: BeatSettings) -> GeneratedBeat {
        var rng = SplitMix64(seed: settings.seed &+ 0x9E37_79B9_7F4A_7C15)
        let steps = max(1, style.stepsPerBar)
        let stepBeats = style.stepBeats
        let barBeats = style.timeSignature.quarterNotesPerBar
        let bars = max(1, settings.bars)
        let phrase = max(1, settings.phraseLength)
        let secondsPerBeat = 60.0 / max(20, settings.tempo)
        let complexity = min(1, max(0, settings.complexity))
        let humanize = min(1, max(0, settings.humanize))
        let swing = min(1, max(0, settings.swing))

        let mainLanes = style.lanes.mapValues(StepKind.parse)
        let extraLanes = style.complexLanes.mapValues(StepKind.parse)
        let fillLanes = style.fills.map { $0.mapValues(StepKind.parse) }

        var notes: [MIDINote] = []
        notes.reserveCapacity(bars * steps * 3)

        for bar in 0..<bars {
            let posInPhrase = bar % phrase
            let isPhraseEnd = posInPhrase == phrase - 1 && bars > 1
            var lanes = mainLanes
            var isFill = false
            if isPhraseEnd, !fillLanes.isEmpty, rng.unit() < settings.fills {
                let fill = fillLanes[Int(rng.next() % UInt64(fillLanes.count))]
                // A fill replaces only the lanes it defines; the rest of the groove continues.
                for (k, v) in fill { lanes[k] = v }
                isFill = true
            }
            if complexity > 0.5 && !isFill {
                for (k, v) in extraLanes {
                    // Layer extra lanes: merge step-wise (existing hits win).
                    if let base = lanes[k], !base.isEmpty {
                        var merged = base
                        let n = max(base.count, v.count)
                        merged = (0..<n).map { i in
                            let a = base[i % base.count], b = v[i % v.count]
                            return a == .rest ? b : a
                        }
                        lanes[k] = merged
                    } else {
                        lanes[k] = v
                    }
                }
            }

            for (laneKey, pattern) in lanes.sorted(by: { $0.key < $1.key }) {
                guard let pitch = DrumMap.note(for: laneKey), !pattern.isEmpty else { continue }
                for s in 0..<steps {
                    // Lane strings longer than one bar continue across bars.
                    let kind = pattern[(bar * steps + s) % pattern.count]
                    var vel: Double
                    switch kind {
                    case .rest: continue
                    case .accent: vel = 118
                    case .normal: vel = 96
                    case .ghost:
                        if complexity < 0.3 { continue }
                        vel = 50
                    case .optional:
                        if rng.unit() >= complexity { continue }
                        vel = 78
                    }
                    var beat = Double(bar) * barBeats + Double(s) * stepBeats
                    // Swing: delay every second step (off-beat 8ths or 16ths depending on grid).
                    if s % 2 == 1 { beat += swing * stepBeats / 3.0 }
                    if humanize > 0 {
                        let jitterSeconds = rng.gaussian() * 0.004 * humanize * 3   // up to ~12 ms
                        beat += jitterSeconds / secondsPerBeat
                        vel += rng.gaussian() * 10 * humanize
                    }
                    beat = max(0, beat)
                    let v = Int(min(127, max(1, vel.rounded())))
                    notes.append(MIDINote(pitch: pitch, velocity: v, startBeat: beat, durationBeats: stepBeats * 0.9))
                }
            }

            // Crash on the downbeat of each phrase (except bar 0 if the style says nothing).
            if posInPhrase == 0 && bar > 0 {
                for lane in style.phraseAccent {
                    if let pitch = DrumMap.note(for: lane) {
                        notes.append(MIDINote(pitch: pitch, velocity: 110, startBeat: Double(bar) * barBeats, durationBeats: stepBeats))
                    }
                }
            }
        }
        notes.sort { ($0.startBeat, $0.pitch) < ($1.startBeat, $1.pitch) }
        return GeneratedBeat(style: style, settings: settings, notes: notes, lengthBeats: Double(bars) * barBeats)
    }
}
