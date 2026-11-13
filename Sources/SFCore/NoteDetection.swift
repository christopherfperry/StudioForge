import Foundation

/// Note naming helpers. Middle C (MIDI 60) is "C4"; A4 = 440 Hz = MIDI 69.
public enum NoteName {
    public static let pitchClasses = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// "C4", "F#2", ... for a MIDI note number.
    public static func name(_ midi: Int) -> String {
        let pc = ((midi % 12) + 12) % 12
        let octave = Int((Double(midi) / 12).rounded(.down)) - 1
        return "\(pitchClasses[pc])\(octave)"
    }

    /// Fractional MIDI note for a frequency in Hz.
    public static func midi(fromFrequency hz: Double) -> Double { 69 + 12 * log2(hz / 440) }

    /// General MIDI percussion names (channel 10), used on drum tracks.
    public static func drumName(_ midi: Int) -> String {
        switch midi {
        case 35, 36: return "Kick"
        case 37: return "Rim"
        case 38, 40: return "Snare"
        case 39: return "Clap"
        case 41, 43: return "Low Tom"
        case 45, 47: return "Mid Tom"
        case 48, 50: return "High Tom"
        case 42: return "Closed Hat"
        case 44: return "Pedal Hat"
        case 46: return "Open Hat"
        case 49, 57: return "Crash"
        case 51, 59: return "Ride"
        case 53: return "Ride Bell"
        case 52: return "China"
        case 55: return "Splash"
        case 54: return "Tambourine"
        case 56: return "Cowbell"
        default: return name(midi)
        }
    }

    /// Short label for a set of sounding notes: "C4", "C4 E4 G4", "Kick + Closed Hat", "C3 E3 G3 B3 +2".
    public static func label(for pitches: [Int], drums: Bool, maxItems: Int = 4) -> String {
        guard !pitches.isEmpty else { return "" }
        var names: [String] = []
        for p in Array(Set(pitches)).sorted() {
            let n = drums ? drumName(p) : name(p)
            if !names.contains(n) { names.append(n) }
        }
        let shown = names.prefix(maxItems).joined(separator: drums ? " + " : " ")
        return names.count > maxItems ? "\(shown) +\(names.count - maxItems)" : shown
    }
}

/// Monophonic pitch track of an audio file (YIN), computed once off the audio thread and then
/// looked up by time while the transport plays. Unvoiced / silent frames hold `nil`.
public struct PitchContour {
    public let hopSeconds: Double
    /// Rounded MIDI note per frame (median-smoothed), nil where no clear pitch was found.
    public let notes: [Int?]

    public init(hopSeconds: Double, notes: [Int?]) { self.hopSeconds = hopSeconds; self.notes = notes }

    public var duration: Double { Double(notes.count) * hopSeconds }

    /// Note sounding at `seconds` into the source file.
    public func note(at seconds: Double) -> Int? {
        guard seconds >= 0, hopSeconds > 0 else { return nil }
        let i = Int(seconds / hopSeconds)
        return i < notes.count ? notes[i] : nil
    }
}

public enum PitchTracker {
    /// Analyses mono samples. Audio is decimated to ~11 kHz first, which keeps a 3-minute song
    /// to roughly a second of work while still covering 50 Hz (low bass) to 1.4 kHz (high vocals).
    public static func contour(samples: [Float], sampleRate: Double,
                               minHz: Double = 50, maxHz: Double = 1400,
                               threshold: Float = 0.15, silenceRMS: Float = 0.01) -> PitchContour {
        let factor = max(1, Int(sampleRate / 11_025))
        let sr = sampleRate / Double(factor)
        var x = [Float](repeating: 0, count: samples.count / factor)
        if factor == 1 { x = samples } else {
            // Box-filter decimation (cheap anti-aliasing; fine for pitch estimation).
            let g = 1 / Float(factor)
            samples.withUnsafeBufferPointer { s in
                for i in 0..<x.count {
                    var acc: Float = 0
                    let b = i * factor
                    for k in 0..<factor { acc += s[b + k] }
                    x[i] = acc * g
                }
            }
        }
        let window = 512
        let hop = 256
        let tauMin = max(2, Int(sr / maxHz))
        let tauMax = min(window - 1, Int(sr / minHz))
        let hopSeconds = Double(hop) / sr
        guard x.count >= window + tauMax else { return PitchContour(hopSeconds: hopSeconds, notes: []) }

        let frames = (x.count - window - tauMax) / hop + 1
        var raw = [Int?](repeating: nil, count: frames)
        var d = [Float](repeating: 0, count: tauMax + 1)
        x.withUnsafeBufferPointer { xp in
            for f in 0..<frames {
                let base = f * hop
                var energy: Float = 0
                for j in 0..<window { let v = xp[base + j]; energy += v * v }
                if (energy / Float(window)).squareRoot() < silenceRMS { continue }
                // Difference function + cumulative mean normalisation (YIN steps 2-3).
                d[0] = 1
                var running: Float = 0
                for tau in 1...tauMax {
                    var sum: Float = 0
                    let a = base, b = base + tau
                    for j in 0..<window { let diff = xp[a + j] - xp[b + j]; sum += diff * diff }
                    running += sum
                    d[tau] = running > 0 ? sum * Float(tau) / running : 1
                }
                // Absolute threshold: first dip below the threshold, then walk to its minimum.
                var tau = tauMin
                var found = -1
                while tau <= tauMax {
                    if d[tau] < threshold {
                        while tau + 1 <= tauMax && d[tau + 1] < d[tau] { tau += 1 }
                        found = tau; break
                    }
                    tau += 1
                }
                guard found > 0 else { continue }
                // Parabolic interpolation for sub-sample period.
                var period = Double(found)
                if found > 1 && found < tauMax {
                    let s0 = d[found - 1], s1 = d[found], s2 = d[found + 1]
                    let den = s0 + s2 - 2 * s1
                    if abs(den) > 1e-9 { period += Double((s0 - s2) / (2 * den)) }
                }
                let hz = sr / period
                guard hz >= minHz * 0.9, hz <= maxHz * 1.1 else { continue }
                raw[f] = Int(NoteName.midi(fromFrequency: hz).rounded())
            }
        }
        // 5-frame median smoothing (drops single-frame octave jumps), keeping gaps as gaps.
        var smooth = raw
        for i in 0..<frames {
            guard raw[i] != nil else { continue }
            let lo = max(0, i - 2), hi = min(frames - 1, i + 2)
            let vals = raw[lo...hi].compactMap { $0 }.sorted()
            if vals.count >= 3 { smooth[i] = vals[vals.count / 2] }
            else { smooth[i] = nil }   // isolated blips are not notes
        }
        return PitchContour(hopSeconds: hopSeconds, notes: smooth)
    }

    public static func contour(_ audio: AudioData) -> PitchContour {
        contour(samples: audio.mono, sampleRate: audio.sampleRate)
    }
}
