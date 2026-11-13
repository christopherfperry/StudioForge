import Foundation
import SFCore

/// Music genre used to shape a generated synth part (register, filter brightness, envelope,
/// waveform and rhythm) so it sits in the style of the source tracks.
public enum MusicGenre: String, CaseIterable, Codable, Identifiable {
    case auto, rock, metal, pop, funk, rnb, hipHop, electronic, ambient, jazz, folk
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .rock: return "Rock"
        case .metal: return "Metal"
        case .pop: return "Pop"
        case .funk: return "Funk"
        case .rnb: return "R&B / Soul"
        case .hipHop: return "Hip-hop"
        case .electronic: return "Electronic"
        case .ambient: return "Ambient"
        case .jazz: return "Jazz"
        case .folk: return "Folk / Acoustic"
        }
    }
    public static var concrete: [MusicGenre] { allCases.filter { $0 != .auto } }
}

/// Audio features of the guitar / bass sources used to guess the genre.
public struct GenreFeatures: Equatable {
    /// 0…1, how distorted/saturated the guitar sounds (spectral flatness + low crest factor).
    public var distortion: Double = 0
    /// Spectral centroid of the guitar in Hz.
    public var brightness: Double = 0
    /// Note onsets per second (guitar + bass).
    public var onsetRate: Double = 0
    /// 0…1, share of time notes are held (high = sustained/legato, low = staccato).
    public var sustain: Double = 0
    /// 0…1, share of bass energy below 60 Hz (sub-bass weight).
    public var subWeight: Double = 0
    public var tempo: Double = 120
    /// Chord changes per bar.
    public var chordRate: Double = 0
    /// Key clarity 0…1 (low = chromatic / jazzy harmony).
    public var keyConfidence: Double = 1
    public init() {}
}

/// Frequency / timbre profile for one genre. Registers are MIDI note ranges: they set the
/// fundamental frequencies the synth plays at; `cutoff` sets the spectral brightness.
public struct GenreToneProfile: Equatable {
    public var genre: MusicGenre
    public var padRange: ClosedRange<Int>
    public var bassRange: ClosedRange<Int>
    public var arpRange: ClosedRange<Int>
    /// Power chords (root + fifth + octave) instead of triads — rock / metal.
    public var powerChords: Bool
    /// Add the diatonic seventh to chords — jazz / R&B.
    public var sevenths: Bool
    /// Arpeggio step in beats.
    public var arpStep: Double
    /// Bass synth note length as a fraction of the detected note (staccato < 1).
    public var bassGate: Double
    public var pad: InstrumentState
    public var bass: InstrumentState
    public var arp: InstrumentState

    func instrument(for style: SynthStyle) -> InstrumentState {
        switch style { case .pad: return pad; case .bassSynth: return bass; case .arpeggio: return arp }
    }
}

public enum GenreTone {
    /// MIDI note → Hz (A4 = 440).
    public static func hz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    // MARK: Feature extraction

    public static func features(guitar: AudioData?, bass: AudioData?, tempo: Double,
                                chords: [DetectedChord], beatsPerBar: Int, keyConfidence: Double) -> GenreFeatures {
        var f = GenreFeatures()
        f.tempo = tempo
        f.keyConfidence = keyConfidence
        var onsets = 0.0, seconds = 0.0, sustainSum = 0.0, sustainN = 0.0
        if let g = guitar {
            let s = spectralStats(g.mono, sampleRate: g.sampleRate)
            f.distortion = s.distortion
            f.brightness = s.centroid
            onsets += s.onsets; seconds = max(seconds, s.seconds)
            sustainSum += s.sustain; sustainN += 1
        }
        if let b = bass {
            let s = spectralStats(b.mono, sampleRate: b.sampleRate)
            f.subWeight = s.subShare
            onsets += s.onsets; seconds = max(seconds, s.seconds)
            sustainSum += s.sustain; sustainN += 1
        }
        f.onsetRate = seconds > 0 ? onsets / seconds : 0
        f.sustain = sustainN > 0 ? sustainSum / sustainN : 0
        let totalBeats = chords.map { $0.startBeat + $0.lengthBeats }.max() ?? 0
        f.chordRate = totalBeats > 0 ? Double(chords.count) / (totalBeats / Double(max(1, beatsPerBar))) : 0
        return f
    }

    struct Stats { var distortion = 0.0, centroid = 0.0, onsets = 0.0, seconds = 0.0, sustain = 0.0, subShare = 0.0 }

    static func spectralStats(_ x: [Float], sampleRate: Double) -> Stats {
        var st = Stats()
        let size = 2048, hop = 1024
        st.seconds = Double(x.count) / sampleRate
        guard x.count >= size else { return st }
        let stft = STFT(frameSize: size, hop: hop)
        let (re, im, frames) = stft.analyze(x)
        let bins = stft.bins
        let binHz = sampleRate / Double(size)
        var energies = [Double](repeating: 0, count: frames)
        var flatSum = 0.0, centSum = 0.0, weightSum = 0.0, sub = 0.0, total = 0.0, high = 0.0, mid = 0.0
        var prev = [Double](repeating: 0, count: bins)
        var flux = [Double](repeating: 0, count: frames)
        for fr in 0..<frames {
            let base = fr * bins
            var e = 0.0, num = 0.0, logSum = 0.0, linSum = 0.0, n = 0.0, fl = 0.0
            for b in 1..<bins {
                let m = Double(re[base + b] * re[base + b] + im[base + b] * im[base + b])
                let hz = Double(b) * binHz
                e += m; num += m * hz
                if hz < 60 { sub += m }
                if hz >= 2500 { high += m } else if hz >= 80 { mid += m }
                if hz >= 100 && hz <= 6000 { logSum += log(m + 1e-12); linSum += m; n += 1 }
                let mag = m.squareRoot()
                fl += max(0, mag - prev[b]); prev[b] = mag
            }
            energies[fr] = e; flux[fr] = fl; total += e
            if e > 1e-9 {
                centSum += num; weightSum += e
                if n > 0 && linSum > 0 { flatSum += exp(logSum / n) / (linSum / n) * e }
            }
        }
        let peak = energies.max() ?? 0
        guard peak > 0, weightSum > 0 else { return st }
        st.centroid = centSum / weightSum
        let flatness = flatSum / weightSum                          // 0 (tonal) … 1 (noise-like)
        // Distortion adds dense upper harmonics (high/mid energy ratio), flattens the spectrum and
        // squares off the waveform (many samples sitting near the peak).
        // Log scales: clean guitar ≈ −25…−30 dB high/mid and ≈ −25 dB flatness; distorted ≈ −10 dB.
        let hrDB = 10 * log10(max(1e-9, mid > 0 ? high / mid : 0))
        let hrTerm = max(0, min(1, (hrDB + 30) / 20))
        var pk: Float = 0
        for v in x { pk = max(pk, abs(v)) }
        var plateau = 0
        if pk > 0 { let th = pk * 0.9; for v in x where abs(v) >= th { plateau += 1 } }
        let plateauTerm = min(1, Double(plateau) / Double(x.count) * 2.5)
        let flatTerm = max(0, min(1, (10 * log10(max(1e-9, flatness)) + 35) / 25))
        st.distortion = max(0, min(1, 0.35 * flatTerm + 0.35 * hrTerm + 0.3 * plateauTerm))
        st.subShare = total > 0 ? sub / total : 0
        // Onsets: peaks in spectral flux above an adaptive threshold.
        let meanFlux = flux.reduce(0, +) / Double(frames)
        var count = 0.0
        for i in 1..<max(1, frames - 1) where flux[i] > meanFlux * 1.6 && flux[i] >= flux[i - 1] && flux[i] > flux[i + 1]
            && energies[i] > peak * 0.01 { count += 1 }
        st.onsets = count
        // Sustain: share of frames above -20 dB of peak.
        st.sustain = Double(energies.filter { $0 > peak * 0.01 }.count) / Double(frames)
        return st
    }

    // MARK: Classification

    /// Rule-based genre guess with a short human-readable reason.
    public static func classify(_ f: GenreFeatures) -> (genre: MusicGenre, reason: String) {
        let t = f.tempo
        if f.distortion > 0.45 {
            if t >= 145 || f.distortion > 0.75 { return (.metal, "heavily distorted guitar, \(Int(t)) BPM") }
            return (.rock, "distorted guitar")
        }
        if f.keyConfidence < 0.35 && f.chordRate >= 1.5 { return (.jazz, "frequent, chromatic chord changes") }
        if t < 80 && f.sustain > 0.75 && f.onsetRate < 1.5 { return (.ambient, "slow, sustained, few attacks") }
        if f.subWeight > 0.35 && t >= 70 && t <= 105 { return (.hipHop, "heavy sub-bass, \(Int(t)) BPM") }
        if f.onsetRate > 4 && f.sustain < 0.6 && t >= 90 && t <= 130 { return (.funk, "busy, staccato guitar and bass") }
        if t >= 118 && t <= 140 && f.sustain > 0.7 && f.brightness > 1800 { return (.electronic, "steady \(Int(t)) BPM, bright sustained parts") }
        if t < 100 && f.brightness < 1500 { return (.rnb, "laid-back tempo, warm tone") }
        if f.brightness > 2200 && f.subWeight < 0.1 && f.onsetRate < 3.5 { return (.folk, "bright, light acoustic-style tone") }
        return (.pop, "clean guitar, mid tempo")
    }

    // MARK: Profiles

    private static func sub(_ p: [String: Float]) -> InstrumentState { InstrumentState(type: "synth.subtractive", params: p) }
    private static func bassSynth(_ p: [String: Float]) -> InstrumentState { InstrumentState(type: "synth.bass", params: p) }
    private static func keys(_ p: [String: Float]) -> InstrumentState { InstrumentState(type: "keys", params: p) }

    /// Wave indices: 0 Saw, 1 Square, 2 Triangle, 3 Sine.
    public static func profile(_ genre: MusicGenre) -> GenreToneProfile {
        switch genre {
        case .metal:
            return GenreToneProfile(genre: genre, padRange: 40...64, bassRange: 23...40, arpRange: 52...71,
                powerChords: true, sevenths: false, arpStep: 0.25, bassGate: 0.9,
                pad: sub(["osc1Wave": 0, "osc2Wave": 1, "osc2Detune": 12, "osc2Level": 0.7, "unison": 5, "unisonDetune": 22,
                          "cutoff": 2600, "resonance": 1.2, "filterEnv": 0.2, "filterDrive": 9, "drive": 0.55,
                          "ampA": 0.01, "ampD": 0.4, "ampS": 0.9, "ampR": 0.25, "gain": -15, "spread": 0.9]),
                bass: bassSynth(["cutoff": 1400, "resonance": 1.2, "drive": 0.7, "subLevel": 0.7, "filterEnv": 0.3, "gain": -10]),
                arp: sub(["osc1Wave": 0, "osc2Wave": 0, "osc2Detune": 9, "cutoff": 3200, "resonance": 2, "filterEnv": 0.4,
                          "filtD": 0.12, "filtS": 0.2, "drive": 0.5, "ampA": 0.002, "ampD": 0.15, "ampS": 0.3, "ampR": 0.1, "gain": -15]))
        case .rock:
            return GenreToneProfile(genre: genre, padRange: 45...67, bassRange: 28...45, arpRange: 55...74,
                powerChords: true, sevenths: false, arpStep: 0.5, bassGate: 0.9,
                pad: sub(["osc1Wave": 0, "osc2Wave": 0, "osc2Detune": 8, "osc2Level": 0.6, "unison": 3, "unisonDetune": 15,
                          "cutoff": 2200, "resonance": 1, "filterEnv": 0.2, "drive": 0.3,
                          "ampA": 0.05, "ampD": 0.5, "ampS": 0.85, "ampR": 0.5, "gain": -15, "spread": 0.8]),
                bass: bassSynth(["cutoff": 900, "resonance": 1.3, "drive": 0.45, "gain": -9]),
                arp: sub(["osc1Wave": 1, "osc2Wave": 0, "cutoff": 2600, "resonance": 1.8, "filterEnv": 0.45, "filtD": 0.15,
                          "filtS": 0.15, "ampA": 0.003, "ampD": 0.2, "ampS": 0.3, "ampR": 0.15, "gain": -14]))
        case .pop:
            return GenreToneProfile(genre: genre, padRange: 55...76, bassRange: 33...50, arpRange: 60...81,
                powerChords: false, sevenths: false, arpStep: 0.25, bassGate: 0.85,
                pad: sub(["osc1Wave": 0, "osc2Wave": 0, "osc2Detune": 9, "osc2Level": 0.6, "unison": 3, "unisonDetune": 18,
                          "cutoff": 3200, "resonance": 0.9, "filterEnv": 0.15, "ampA": 0.25, "ampD": 0.8, "ampS": 0.85,
                          "ampR": 1.0, "lfoRate": 0.3, "lfoCutoff": 0.2, "gain": -14, "spread": 0.85]),
                bass: bassSynth(["cutoff": 1100, "resonance": 1.4, "drive": 0.2, "gain": -9]),
                arp: sub(["osc1Wave": 1, "osc2Wave": 0, "osc2Detune": 6, "osc2Level": 0.4, "cutoff": 3500, "resonance": 2,
                          "filterEnv": 0.5, "filtD": 0.15, "filtS": 0.1, "ampA": 0.002, "ampD": 0.2, "ampS": 0.25,
                          "ampR": 0.18, "gain": -13, "spread": 0.7]))
        case .funk:
            return GenreToneProfile(genre: genre, padRange: 55...74, bassRange: 31...48, arpRange: 60...79,
                powerChords: false, sevenths: true, arpStep: 0.25, bassGate: 0.55,
                pad: sub(["osc1Wave": 1, "osc2Wave": 0, "pulseWidth": 0.3, "cutoff": 2400, "resonance": 2.5,
                          "filterEnv": 0.6, "filtD": 0.18, "filtS": 0.2, "ampA": 0.003, "ampD": 0.25, "ampS": 0.5,
                          "ampR": 0.12, "gain": -14]),
                bass: bassSynth(["cutoff": 600, "resonance": 3.5, "filterEnv": 0.75, "filtD": 0.12, "drive": 0.2, "gain": -9]),
                arp: sub(["osc1Wave": 1, "pulseWidth": 0.25, "cutoff": 3000, "resonance": 3, "filterEnv": 0.7,
                          "filtD": 0.1, "filtS": 0, "ampA": 0.001, "ampD": 0.12, "ampS": 0, "ampR": 0.08, "gain": -13]))
        case .rnb:
            return GenreToneProfile(genre: genre, padRange: 52...72, bassRange: 28...45, arpRange: 57...76,
                powerChords: false, sevenths: true, arpStep: 0.5, bassGate: 0.95,
                pad: keys(["model": 2, "brightness": 0.35, "modDepth": 0.35, "modRate": 4.5, "release": 0.8, "gain": -10]),
                bass: bassSynth(["osc1Wave": 3, "cutoff": 450, "resonance": 0.8, "drive": 0.1, "glide": 60, "gain": -8]),
                arp: keys(["model": 1, "brightness": 0.45, "release": 0.5, "gain": -11]))
        case .hipHop:
            return GenreToneProfile(genre: genre, padRange: 50...70, bassRange: 24...40, arpRange: 60...79,
                powerChords: false, sevenths: true, arpStep: 0.5, bassGate: 1.0,
                pad: sub(["osc1Wave": 2, "osc2Wave": 0, "osc2Level": 0.3, "cutoff": 1300, "resonance": 0.8, "filterEnv": 0.1,
                          "ampA": 0.4, "ampD": 1, "ampS": 0.8, "ampR": 1.2, "gain": -15, "spread": 0.7]),
                // 808-style sine sub with a slow glide.
                bass: bassSynth(["osc1Wave": 3, "osc2Level": 0, "subLevel": 0.8, "cutoff": 300, "resonance": 0.7,
                                 "filterEnv": 0, "drive": 0.25, "ampD": 1.2, "ampS": 0.6, "ampR": 0.3, "glide": 80, "gain": -7]),
                arp: sub(["osc1Wave": 3, "osc2Wave": 2, "cutoff": 2500, "ampA": 0.002, "ampD": 0.4, "ampS": 0.2, "ampR": 0.4, "gain": -14]))
        case .electronic:
            return GenreToneProfile(genre: genre, padRange: 57...79, bassRange: 31...48, arpRange: 62...86,
                powerChords: false, sevenths: false, arpStep: 0.25, bassGate: 0.5,
                pad: sub(["osc1Wave": 0, "osc2Wave": 0, "osc2Detune": 12, "osc2Level": 0.8, "unison": 7, "unisonDetune": 30,
                          "cutoff": 5000, "resonance": 1.2, "filterEnv": 0.2, "ampA": 0.08, "ampD": 0.6, "ampS": 0.9,
                          "ampR": 0.8, "lfoRate": 0.25, "lfoCutoff": 0.4, "gain": -16, "spread": 1]),
                bass: bassSynth(["osc1Wave": 0, "cutoff": 1500, "resonance": 2.5, "filterEnv": 0.55, "filtD": 0.15, "drive": 0.35, "gain": -10]),
                arp: sub(["osc1Wave": 0, "osc2Wave": 1, "osc2Detune": 7, "cutoff": 4200, "resonance": 3, "filterEnv": 0.55,
                          "filtD": 0.1, "filtS": 0.05, "ampA": 0.001, "ampD": 0.12, "ampS": 0.15, "ampR": 0.12, "gain": -14, "spread": 0.8]))
        case .ambient:
            return GenreToneProfile(genre: genre, padRange: 55...84, bassRange: 28...45, arpRange: 67...91,
                powerChords: false, sevenths: false, arpStep: 0.5, bassGate: 1.0,
                pad: sub(["osc1Wave": 2, "osc2Wave": 0, "osc2Detune": 6, "osc2Level": 0.4, "unison": 5, "unisonDetune": 12,
                          "cutoff": 1100, "resonance": 0.7, "filterEnv": 0.1, "ampA": 2.0, "ampD": 1.5, "ampS": 0.9,
                          "ampR": 4.0, "lfoRate": 0.12, "lfoCutoff": 0.5, "gain": -15, "spread": 1]),
                bass: bassSynth(["osc1Wave": 3, "cutoff": 350, "resonance": 0.7, "drive": 0, "ampA": 0.2, "ampR": 1.0, "gain": -10]),
                arp: sub(["osc1Wave": 3, "osc2Wave": 2, "cutoff": 1800, "ampA": 0.01, "ampD": 0.8, "ampS": 0.3, "ampR": 1.5, "gain": -15, "spread": 1]))
        case .jazz:
            return GenreToneProfile(genre: genre, padRange: 50...70, bassRange: 28...48, arpRange: 55...76,
                powerChords: false, sevenths: true, arpStep: 0.5, bassGate: 0.9,
                pad: keys(["model": 2, "brightness": 0.3, "modDepth": 0.15, "release": 0.6, "gain": -10]),
                bass: bassSynth(["osc1Wave": 2, "osc2Level": 0.2, "subLevel": 0.3, "cutoff": 600, "resonance": 0.8,
                                 "filterEnv": 0.3, "filtD": 0.3, "drive": 0, "ampD": 0.6, "ampS": 0.3, "ampR": 0.15, "gain": -9]),
                arp: keys(["model": 1, "brightness": 0.35, "release": 0.4, "gain": -11]))
        case .folk:
            return GenreToneProfile(genre: genre, padRange: 52...74, bassRange: 33...50, arpRange: 60...79,
                powerChords: false, sevenths: false, arpStep: 0.5, bassGate: 0.9,
                pad: keys(["model": 5, "brightness": 0.4, "attack": 0.6, "release": 1.2, "ensemble": 0.6, "gain": -12]),
                bass: bassSynth(["osc1Wave": 2, "osc2Level": 0.2, "cutoff": 700, "resonance": 0.8, "drive": 0, "gain": -10]),
                arp: keys(["model": 0, "brightness": 0.5, "release": 0.8, "gain": -10]))
        case .auto:
            return profile(.pop)
        }
    }
}
