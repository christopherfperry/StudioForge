import Foundation
import SFCore

/// Style of an auto-generated synth part.
public enum SynthStyle: String, CaseIterable, Codable, Identifiable {
    case pad, bassSynth, arpeggio
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .pad: return "Pad (follows chords)"
        case .bassSynth: return "Bass synth (doubles bass)"
        case .arpeggio: return "Arpeggio"
        }
    }
    public var trackName: String {
        switch self { case .pad: return "Synth Pad"; case .bassSynth: return "Synth Bass"; case .arpeggio: return "Synth Arp" }
    }
}

/// A chord over a span of beats (relative to the start of the analysed audio).
public struct DetectedChord: Hashable {
    public var root: Int        // pitch class, 0 = C
    public var minor: Bool
    public var startBeat: Double
    public var lengthBeats: Double
    public var name: String { NoteName.pitchClasses[root] + (minor ? "m" : "") }
    /// Pitch classes of the triad.
    public var pitchClasses: [Int] { [root, (root + (minor ? 3 : 4)) % 12, (root + 7) % 12] }
}

/// A quantised monophonic note (beats relative to the start of the analysed audio).
public struct QuantisedNote: Hashable {
    public var pitch: Int
    public var startBeat: Double
    public var lengthBeats: Double
}

public struct SynthGenerationResult {
    public var notes: [MIDINote]
    public var lengthBeats: Double
    public var chords: [DetectedChord]
    public var bassNotes: [QuantisedNote]
    public var keyRoot: Int
    public var keyIsMinor: Bool
    public var keyName: String { NoteName.pitchClasses[keyRoot] + (keyIsMinor ? " minor" : " major") }
    public var instrument: InstrumentState
    public var trackName: String
    /// Genre whose register / timbre profile shaped the part, and why it was chosen.
    public var genre: MusicGenre = .pop
    public var genreReason: String = ""
    public var features = GenreFeatures()
}

/// Builds a synth part that matches existing guitar and/or bass audio:
///  - key from combined chroma (Krumhansl profiles, shared with `AudioAnalyzer`);
///  - chords from beat-synchronous chroma matched to major/minor triad templates, favouring
///    diatonic chords when the key is clear and the bass note as root;
///  - bass line from the YIN pitch tracker, quantised to the grid and snapped to the key scale.
/// All positions are in beats from the start of the audio; the caller adds the clip offset.
public struct SynthTrackGenerator {
    public var tempo: Double
    public var beatsPerBar: Int
    /// Note grid in beats (0.5 = eighth notes).
    public var grid: Double = 0.5
    /// Chord analysis window in beats.
    public var chordBeats: Double = 2

    public init(tempo: Double, beatsPerBar: Int = 4) {
        self.tempo = max(20, tempo); self.beatsPerBar = max(1, beatsPerBar)
    }

    var secondsPerBeat: Double { 60 / tempo }

    public static let majorScale = [0, 2, 4, 5, 7, 9, 11]
    public static let minorScale = [0, 2, 3, 5, 7, 8, 10]

    public static func scale(root: Int, minor: Bool) -> Set<Int> {
        Set((minor ? minorScale : majorScale).map { ($0 + root) % 12 })
    }

    // MARK: - Chroma

    /// Chroma per analysis frame (55 Hz – 2 kHz) plus frame energy.
    static func chromaFrames(_ samples: [Float], sampleRate: Double) -> (chroma: [[Double]], energy: [Double], hopSeconds: Double) {
        let size = 4096, hop = 1024
        guard samples.count >= size else { return ([], [], Double(hop) / sampleRate) }
        let stft = STFT(frameSize: size, hop: hop)
        let (re, im, frames) = stft.analyze(samples)
        let bins = stft.bins
        let binHz = sampleRate / Double(size)
        let pc: [Int] = (0..<bins).map { b in
            let f = Double(b) * binHz
            guard f >= 55, f <= 2000 else { return -1 }
            return ((Int(NoteName.midi(fromFrequency: f).rounded()) % 12) + 12) % 12
        }
        var out = [[Double]](repeating: [Double](repeating: 0, count: 12), count: frames)
        var energy = [Double](repeating: 0, count: frames)
        for f in 0..<frames {
            let base = f * bins
            for b in 0..<bins {
                let m = Double(re[base + b] * re[base + b] + im[base + b] * im[base + b])
                energy[f] += m
                if pc[b] >= 0 { out[f][pc[b]] += m.squareRoot() }
            }
        }
        return (out, energy, Double(hop) / sampleRate)
    }

    /// Key from the summed chroma of all sources: (root, minor, confidence).
    public func detectKey(_ sources: [AudioData]) -> (root: Int, minor: Bool, confidence: Double) {
        var total = [Double](repeating: 0, count: 12)
        for s in sources {
            for c in Self.chromaFrames(s.mono, sampleRate: s.sampleRate).chroma { for k in 0..<12 { total[k] += c[k] } }
        }
        guard total.reduce(0, +) > 0 else { return (0, false, 0) }
        let k = AudioAnalyzer.detectKey(total)
        return (k.0, k.1, k.2)
    }

    // MARK: - Chords

    /// Chords per `chordBeats` window; silent windows are skipped and repeats merged.
    public func detectChords(_ audio: AudioData, bass: [QuantisedNote] = [], keyRoot: Int, minor: Bool,
                             keyConfidence: Double) -> [DetectedChord] {
        let (frames, energy, hopSec) = Self.chromaFrames(audio.mono, sampleRate: audio.sampleRate)
        guard !frames.isEmpty else { return [] }
        let window = chordBeats * secondsPerBeat
        let duration = Double(audio.frameCount) / audio.sampleRate
        let windows = max(1, Int((duration / window).rounded(.up)))
        let peakEnergy = energy.max() ?? 0
        let scale = Self.scale(root: keyRoot, minor: minor)
        var chords: [DetectedChord] = []
        for w in 0..<windows {
            let t0 = Double(w) * window, t1 = t0 + window
            let f0 = Int(t0 / hopSec), f1 = min(frames.count, Int(t1 / hopSec))
            guard f1 > f0 else { continue }
            var chroma = [Double](repeating: 0, count: 12)
            var e = 0.0
            for f in f0..<f1 { e += energy[f]; for k in 0..<12 { chroma[k] += frames[f][k] } }
            guard e / Double(f1 - f0) > peakEnergy * 1e-3 else { continue }
            // Bass note in this window strengthens its pitch class as the chord root.
            let startBeat = Double(w) * chordBeats
            let bassPC = bass.first { $0.startBeat < startBeat + chordBeats && $0.startBeat + $0.lengthBeats > startBeat }
                .map { (($0.pitch % 12) + 12) % 12 }
            let best = Self.bestTriad(chroma, scale: keyConfidence > 0.4 ? scale : nil, bassPC: bassPC)
            if var last = chords.last, last.root == best.root, last.minor == best.minor,
               abs(last.startBeat + last.lengthBeats - startBeat) < 1e-6 {
                last.lengthBeats += chordBeats
                chords[chords.count - 1] = last
            } else {
                chords.append(DetectedChord(root: best.root, minor: best.minor, startBeat: startBeat, lengthBeats: chordBeats))
            }
        }
        return chords
    }

    /// Best major/minor triad for a chroma vector (cosine similarity with weighted templates).
    static func bestTriad(_ chroma: [Double], scale: Set<Int>?, bassPC: Int?) -> (root: Int, minor: Bool) {
        let norm = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return (0, false) }
        var best = (root: 0, minor: false, score: -Double.infinity)
        for root in 0..<12 {
            for minor in [false, true] {
                var t = [Double](repeating: 0, count: 12)
                t[root] = 1; t[(root + (minor ? 3 : 4)) % 12] = 0.8; t[(root + 7) % 12] = 0.8
                let tn = sqrt(t.reduce(0) { $0 + $1 * $1 })
                var score = 0.0
                for k in 0..<12 { score += chroma[k] * t[k] }
                score /= norm * tn
                if let s = scale {
                    let tones = [root, (root + (minor ? 3 : 4)) % 12, (root + 7) % 12]
                    if tones.allSatisfy({ s.contains($0) }) { score += 0.08 }
                }
                if bassPC == root { score += 0.06 }
                if score > best.score { best = (root, minor, score) }
            }
        }
        return (best.root, best.minor)
    }

    // MARK: - Bass

    /// Monophonic bass notes: YIN contour → segments → grid-quantised, key-snapped notes.
    public func bassNotes(_ audio: AudioData, keyRoot: Int, minor: Bool, snapToKey: Bool = true) -> [QuantisedNote] {
        let contour = PitchTracker.contour(samples: audio.mono, sampleRate: audio.sampleRate, minHz: 38, maxHz: 400)
        let hop = contour.hopSeconds
        var segments: [(pitch: Int, start: Int, end: Int)] = []
        for (i, n) in contour.notes.enumerated() {
            guard let p = n else { continue }
            if var last = segments.last, last.pitch == p, i - last.end <= 2 {
                last.end = i; segments[segments.count - 1] = last
            } else {
                segments.append((p, i, i))
            }
        }
        let scale = Self.scale(root: keyRoot, minor: minor)
        var notes: [QuantisedNote] = []
        for s in segments {
            let startSec = Double(s.start) * hop, endSec = Double(s.end + 1) * hop
            guard endSec - startSec >= 0.08 else { continue }
            let start = quantise(startSec / secondsPerBeat)
            var end = quantise(endSec / secondsPerBeat)
            if end <= start { end = start + grid }
            var pitch = s.pitch
            if snapToKey { pitch = Self.snap(pitch, to: scale) }
            if var last = notes.last {
                if start < last.startBeat + last.lengthBeats {
                    if start <= last.startBeat { // same grid slot: keep the longer note
                        if end - start > last.lengthBeats { notes[notes.count - 1] = QuantisedNote(pitch: pitch, startBeat: start, lengthBeats: end - start) }
                        continue
                    }
                    last.lengthBeats = start - last.startBeat
                    notes[notes.count - 1] = last
                }
                if last.pitch == pitch && abs(last.startBeat + last.lengthBeats - start) < 1e-9 && end - start < grid * 1.01 {
                    // Tiny re-trigger of the same pitch: extend instead.
                    notes[notes.count - 1].lengthBeats = end - last.startBeat
                    continue
                }
            }
            notes.append(QuantisedNote(pitch: pitch, startBeat: start, lengthBeats: end - start))
        }
        return notes
    }

    func quantise(_ beat: Double) -> Double { (beat / grid).rounded() * grid }

    /// Moves an out-of-key pitch to the nearest scale tone (ties go down).
    static func snap(_ pitch: Int, to scale: Set<Int>) -> Int {
        guard !scale.isEmpty, !scale.contains(((pitch % 12) + 12) % 12) else { return pitch }
        for d in 1...6 {
            if scale.contains((((pitch - d) % 12) + 12) % 12) { return pitch - d }
            if scale.contains((((pitch + d) % 12) + 12) % 12) { return pitch + d }
        }
        return pitch
    }

    // MARK: - Generation

    /// - Parameter genre: `.auto` guesses the genre from the audio; otherwise the given genre's
    ///   register (note frequencies), chord voicing, rhythm and synth timbre are used.
    public func generate(style: SynthStyle, guitar: AudioData?, bass: AudioData?,
                         genre: MusicGenre = .auto) -> SynthGenerationResult {
        let sources = [guitar, bass].compactMap { $0 }
        let key = detectKey(sources)
        let bassLine = bass.map { bassNotes($0, keyRoot: key.root, minor: key.minor, snapToKey: key.confidence > 0.3) } ?? []
        var chords: [DetectedChord] = []
        if let g = guitar {
            chords = detectChords(g, bass: bassLine, keyRoot: key.root, minor: key.minor, keyConfidence: key.confidence)
        } else if !bassLine.isEmpty {
            chords = chordsFromBass(bassLine, keyRoot: key.root, minor: key.minor)
        }
        let duration = sources.map { Double($0.frameCount) / $0.sampleRate }.max() ?? 0
        let bar = Double(beatsPerBar)
        let lengthBeats = max(bar, ((duration / secondsPerBeat) / bar).rounded(.up) * bar)

        let features = GenreTone.features(guitar: guitar, bass: bass, tempo: tempo, chords: chords,
                                          beatsPerBar: beatsPerBar, keyConfidence: key.confidence)
        let chosen: (genre: MusicGenre, reason: String) = genre == .auto ? GenreTone.classify(features) : (genre, "chosen manually")
        let prof = GenreTone.profile(chosen.genre)
        let scale = Self.scale(root: key.root, minor: key.minor)

        var notes: [MIDINote] = []
        switch style {
        case .pad:
            var previous: [Int] = []
            for c in chords {
                let voicing = Self.voice(c, near: previous, profile: prof, scale: scale, range: prof.padRange)
                previous = voicing
                for p in voicing { notes.append(MIDINote(pitch: p, velocity: 80, startBeat: c.startBeat, durationBeats: c.lengthBeats)) }
                let root = Self.fold(c.root, low: prof.bassRange.lowerBound + 7, high: prof.bassRange.lowerBound + 18)
                if root < voicing.first ?? 127 {
                    notes.append(MIDINote(pitch: root, velocity: 70, startBeat: c.startBeat, durationBeats: c.lengthBeats))
                }
            }
        case .bassSynth:
            let lo = prof.bassRange.lowerBound, hi = prof.bassRange.upperBound
            if !bassLine.isEmpty {
                for n in bassLine {
                    notes.append(MIDINote(pitch: Self.fold(n.pitch, low: lo, high: hi), velocity: 100,
                                          startBeat: n.startBeat, durationBeats: max(0.05, n.lengthBeats * prof.bassGate)))
                }
            } else {
                for c in chords {
                    var b = c.startBeat
                    while b < c.startBeat + c.lengthBeats - 1e-9 {
                        notes.append(MIDINote(pitch: Self.fold(c.root, low: lo, high: min(hi, lo + 11)), velocity: b == c.startBeat ? 105 : 90,
                                              startBeat: b, durationBeats: grid * prof.bassGate))
                        b += grid
                    }
                }
            }
        case .arpeggio:
            let step = prof.arpStep
            var previous: [Int] = []
            for c in chords {
                let v = Self.voice(c, near: previous, profile: prof, scale: scale, range: prof.arpRange)
                previous = v
                var pattern = v + [v[0] + 12]
                pattern += v.dropFirst().reversed()                        // up-down
                pattern = pattern.map { Self.fold($0, low: prof.arpRange.lowerBound, high: prof.arpRange.upperBound) }
                var b = c.startBeat, i = 0
                while b < c.startBeat + c.lengthBeats - 1e-9 {
                    let accent = abs(b.rounded() - b) < 1e-9
                    notes.append(MIDINote(pitch: pattern[i % pattern.count], velocity: accent ? 96 : 78,
                                          startBeat: b, durationBeats: step * 0.9))
                    b += step; i += 1
                }
            }
        }
        notes = notes.filter { $0.startBeat < lengthBeats }.sorted { ($0.startBeat, $0.pitch) < ($1.startBeat, $1.pitch) }
        return SynthGenerationResult(notes: notes, lengthBeats: lengthBeats, chords: chords, bassNotes: bassLine,
                                     keyRoot: key.root, keyIsMinor: key.minor,
                                     instrument: prof.instrument(for: style),
                                     trackName: "\(style.trackName) (\(chosen.genre.displayName))",
                                     genre: chosen.genre, genreReason: chosen.reason, features: features)
    }

    /// Genre-aware voicing: power chords (root-5th-octave) for rock/metal, added diatonic 7ths for
    /// jazz/R&B/funk/hip-hop, otherwise a close triad — kept inside the genre's register.
    static func voice(_ chord: DetectedChord, near previous: [Int], profile: GenreToneProfile,
                      scale: Set<Int>, range: ClosedRange<Int>) -> [Int] {
        if profile.powerChords {
            // Lowest root that fits root + fifth + octave in the range.
            var root = range.lowerBound + ((chord.root - range.lowerBound) % 12 + 12) % 12
            if root + 12 > range.upperBound { root -= 12 }
            if root < range.lowerBound && root + 12 + 12 <= range.upperBound { root += 12 }
            return [root, root + 7, root + 12]
        }
        var triad = voice(chord, near: previous, low: range.lowerBound, high: range.upperBound)
        if profile.sevenths {
            let major7 = (chord.root + 11) % 12, minor7 = (chord.root + 10) % 12
            // Diatonic seventh only — never add a note outside the key.
            let options = chord.minor ? [minor7] : [major7, minor7]
            guard let pc = options.first(where: { scale.isEmpty || scale.contains($0) }) else { return triad }
            var p = (triad.last ?? 60) + 1
            while ((p % 12) + 12) % 12 != pc { p += 1 }
            if p > range.upperBound { p -= 12 }
            if !triad.contains(p) { triad.append(p); triad.sort() }
        }
        return triad
    }

    /// Chords implied by the bass line: diatonic triad on each bass note's pitch class, one per window.
    func chordsFromBass(_ bass: [QuantisedNote], keyRoot: Int, minor: Bool) -> [DetectedChord] {
        let scale = Self.scale(root: keyRoot, minor: minor)
        var chords: [DetectedChord] = []
        guard let lastEnd = bass.map({ $0.startBeat + $0.lengthBeats }).max() else { return [] }
        var b = 0.0
        while b < lastEnd {
            // Longest-sounding bass pitch class in the window.
            var weight = [Double](repeating: 0, count: 12)
            for n in bass {
                let ov = min(b + chordBeats, n.startBeat + n.lengthBeats) - max(b, n.startBeat)
                if ov > 0 { weight[((n.pitch % 12) + 12) % 12] += ov }
            }
            if let mx = weight.max(), mx > 0, let root = weight.firstIndex(of: mx) {
                let isMinor = scale.contains((root + 3) % 12) && !scale.contains((root + 4) % 12)
                if var last = chords.last, last.root == root, last.minor == isMinor {
                    last.lengthBeats += chordBeats; chords[chords.count - 1] = last
                } else {
                    chords.append(DetectedChord(root: root, minor: isMinor, startBeat: b, lengthBeats: chordBeats))
                }
            }
            b += chordBeats
        }
        return chords
    }

    /// Close triad voicing within [low, high], chosen to move as little as possible from `near`.
    static func voice(_ chord: DetectedChord, near previous: [Int], low: Int, high: Int) -> [Int] {
        var candidates: [[Int]] = []
        for inversion in 0..<3 {
            let pcs = chord.pitchClasses
            let order = Array(pcs[inversion...] + pcs[..<inversion])
            for octave in 3...6 {
                var v: [Int] = []
                var last = -1
                for pc in order {
                    var p = octave * 12 + pc
                    while p <= last { p += 12 }
                    v.append(p); last = p
                }
                if v.first! >= low && v.last! <= high { candidates.append(v) }
            }
        }
        if candidates.isEmpty { return chord.pitchClasses.map { 60 + $0 }.sorted() }
        guard !previous.isEmpty else { return candidates.min { abs($0[0] - 60) < abs($1[0] - 60) }! }
        func cost(_ v: [Int]) -> Int { zip(v, previous).reduce(0) { $0 + abs($1.0 - $1.1) } }
        return candidates.min { cost($0) < cost($1) }!
    }

    /// Octave-folds a pitch into [low, high].
    static func fold(_ p: Int, low: Int, high: Int) -> Int {
        var x = p
        while x < low { x += 12 }
        while x > high { x -= 12 }
        return x
    }

    /// Instrument settings per style (types registered in SFInstruments).
    public static func instrument(for style: SynthStyle) -> InstrumentState {
        switch style {
        case .pad:
            return InstrumentState(type: "synth.subtractive", params: [
                "osc1Wave": 0, "osc2Wave": 0, "osc2Detune": 9, "osc2Level": 0.6, "unison": 3, "unisonDetune": 18,
                "cutoff": 1800, "resonance": 0.9, "filterEnv": 0.15, "ampA": 0.6, "ampD": 0.8, "ampS": 0.85,
                "ampR": 1.5, "lfoRate": 0.3, "lfoCutoff": 0.3, "gain": -14, "spread": 0.85,
            ])
        case .bassSynth:
            return InstrumentState(type: "synth.bass", params: ["cutoff": 800, "gain": -9])
        case .arpeggio:
            return InstrumentState(type: "synth.subtractive", params: [
                "osc1Wave": 1, "osc2Wave": 0, "osc2Detune": 6, "osc2Level": 0.4, "cutoff": 2200, "resonance": 2,
                "filterEnv": 0.5, "filtD": 0.15, "filtS": 0.1, "ampA": 0.002, "ampD": 0.2, "ampS": 0.25,
                "ampR": 0.18, "gain": -13, "spread": 0.7,
            ])
        }
    }
}
