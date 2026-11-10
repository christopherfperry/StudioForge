import Foundation
import SFCore

/// "Match to recording": analyses a recording and generates a beat that fits its tempo, groove
/// (swing), density (complexity) and energy, aligned to the first detected beat.
public struct BeatMatcher {
    public struct Result {
        public var analysis: AudioAnalysis
        public var beat: GeneratedBeat
        /// Seconds from the start of the recording to the first bar line of the generated beat.
        public var startOffsetSeconds: Double
        /// Same offset in beats at the detected tempo.
        public var startOffsetBeats: Double
    }

    public var analyzer = AudioAnalyzer()
    public var generator = BeatGenerator()

    public init() {}

    /// - Parameters:
    ///   - preferredStyle: use this style if given; otherwise one is chosen from `styles`.
    ///   - genreHint: restricts automatic choice to styles whose genre/id contains this text.
    public func match(audio: AudioData, styles: [BeatStyle], preferredStyle: BeatStyle? = nil, genreHint: String? = nil,
                      seed: UInt64 = 1) -> Result? {
        let analysis = analyzer.analyze(audio)
        return match(analysis: analysis, styles: styles, preferredStyle: preferredStyle, genreHint: genreHint, seed: seed)
    }

    public func match(analysis: AudioAnalysis, styles: [BeatStyle], preferredStyle: BeatStyle? = nil,
                      genreHint: String? = nil, seed: UInt64 = 1) -> Result? {
        guard let style = preferredStyle ?? chooseStyle(for: analysis, from: styles, genreHint: genreHint) else { return nil }
        var bpm = analysis.bpm
        // Fold the detected tempo into the style's range (half/double time) if that is closer.
        for candidate in [bpm / 2, bpm * 2] where abs(candidate - style.defaultTempo) < abs(bpm - style.defaultTempo)
            && candidate >= style.minTempo * 0.8 && candidate <= style.maxTempo * 1.2 {
            bpm = candidate
        }
        let barBeats = style.timeSignature.quarterNotesPerBar
        let bars = max(1, Int(ceil(analysis.duration / (60 / bpm) / barBeats)))
        let complexity = min(1, max(0.15, analysis.onsetDensity / 8))
        let settings = BeatSettings(tempo: bpm, bars: bars, swing: analysis.swing, humanize: 0.15,
                                    complexity: complexity, fills: 0.3 + 0.5 * analysis.energy, phraseLength: 4, seed: seed)
        let beat = generator.generate(style: style, settings: settings)
        let first = analysis.beats.first ?? 0
        return Result(analysis: analysis, beat: beat, startOffsetSeconds: first, startOffsetBeats: first / (60 / bpm))
    }

    /// Picks the style whose tempo range best fits and whose intensity matches the energy.
    public func chooseStyle(for a: AudioAnalysis, from styles: [BeatStyle], genreHint: String? = nil) -> BeatStyle? {
        var pool = styles
        if let hint = genreHint?.lowercased(), !hint.isEmpty {
            let filtered = styles.filter { $0.genre.lowercased().contains(hint) || $0.id.lowercased().contains(hint) || $0.artistStyle.lowercased().contains(hint) }
            if !filtered.isEmpty { pool = filtered }
        }
        func score(_ s: BeatStyle) -> Double {
            var sc = 0.0
            for bpm in [a.bpm, a.bpm / 2, a.bpm * 2] {
                let inRange = bpm >= s.minTempo && bpm <= s.maxTempo
                let d = abs(bpm - s.defaultTempo) / max(1, s.defaultTempo)
                sc = max(sc, (inRange ? 1.0 : 0.3) - d)
            }
            // Heavier/denser styles for high energy recordings.
            let density = Double(s.lanes.values.reduce(0) { $0 + StepKind.parse($1).filter { $0 != .rest }.count }) / Double(max(1, s.stepsPerBar))
            sc -= abs(min(1, density / 3) - a.energy) * 0.4
            // Prefer swung styles for swung recordings.
            sc -= abs(s.defaultSwing - a.swing) * 0.3
            return sc
        }
        return pool.max { score($0) < score($1) }
    }
}
