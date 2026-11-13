import Foundation
import SFCore

/// Stems that Fitzrovia Records DAW can produce.
public enum Stem: String, CaseIterable, Codable, Identifiable, Hashable {
    case vocals, bass, drums, guitar, piano, other
    case kick, snare, toms, hihat, cymbals
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vocals: return "Vocals"; case .bass: return "Bass"; case .drums: return "Drums (full)"
        case .guitar: return "Guitar"; case .piano: return "Piano / Keys"; case .other: return "Other"
        case .kick: return "Kick"; case .snare: return "Snare"; case .toms: return "Toms"
        case .hihat: return "Hi-Hat"; case .cymbals: return "Cymbals"
        }
    }
    public static let drumParts: [Stem] = [.kick, .snare, .toms, .hihat, .cymbals]
    public var isDrumPart: Bool { Stem.drumParts.contains(self) }
    /// Main (non drum-part) stems in display order.
    public static let mainStems: [Stem] = [.vocals, .drums, .bass, .guitar, .piano, .other]
    /// Stable ordering for track creation (vocals first, drum parts after the full drum stem).
    public var sortIndex: Int { Stem.allCases.firstIndex(of: self) ?? 0 }
}

/// Separation quality. `.high` uses two-pass HPSS, coherence-based centre detection, pitch-aware
/// bass, Wiener refinement and short-window drum refinement (slower, cleaner).
public enum SeparationQuality: String, CaseIterable, Codable, Identifiable {
    case standard, high
    public var id: String { rawValue }
    public var displayName: String { self == .standard ? "Standard (fast)" : "High (slower)" }
}

public struct SeparationOptions {
    public var stems: Set<Stem>
    /// Split the drum stem further into kick / snare / toms / hi-hat / cymbals.
    public var splitDrums: Bool
    public var quality: SeparationQuality
    /// Artefact reduction strength, 0 (off) … 1 (strongest).
    public var artefactReduction: Float
    public init(stems: Set<Stem> = [.vocals, .bass, .drums, .guitar, .other], splitDrums: Bool = true,
                quality: SeparationQuality = .standard, artefactReduction: Float = 0) {
        self.stems = stems; self.splitDrums = splitDrums
        self.quality = quality; self.artefactReduction = min(1, max(0, artefactReduction))
    }
    /// Vocals + instrumental-style 4 stems.
    public static let fourStem = SeparationOptions(stems: [.vocals, .drums, .bass, .other], splitDrums: false)
    /// Everything: 6 instrument stems plus kick / snare / toms / hi-hat / cymbals.
    public static let full = SeparationOptions(stems: Set(Stem.mainStems), splitDrums: true)
    /// Drum kit only: kick / snare / toms / hi-hat / cymbals.
    public static let drumsOnly = SeparationOptions(stems: [], splitDrums: true)

    /// The stems a separator is expected to return for these options.
    public var expectedStems: [Stem] {
        var out = stems.filter { !$0.isDrumPart }
        if splitDrums { out.formUnion(Stem.drumParts) }
        return out.sorted { $0.sortIndex < $1.sortIndex }
    }
    public var isEmpty: Bool { stems.filter { !$0.isDrumPart }.isEmpty && !splitDrums }
}

/// Progress callback: fraction 0...1 and a human-readable stage. Called from the worker thread.
public typealias SeparationProgress = (Double, String) -> Void

/// Something that splits a mix into stems. Implementations: `DSPStemSeparator` (always available)
/// and `CoreMLStemSeparator` (macOS, needs the downloaded/converted Demucs model).
public protocol StemSeparator {
    var name: String { get }
    /// Runs synchronously; call from a background queue. Check `isCancelled` to abort.
    func separate(_ audio: AudioData, options: SeparationOptions, progress: SeparationProgress,
                  isCancelled: () -> Bool) throws -> [Stem: AudioData]
}

/// Writes separated stems as 24-bit WAV files named "<base> - <Stem>.wav". Returns the URLs.
public enum StemWriter {
    public static func write(_ stems: [Stem: AudioData], baseName: String, to folder: URL) throws -> [Stem: URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var out: [Stem: URL] = [:]
        let fm = FileManager.default
        let safeBase = baseName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        for (stem, audio) in stems.sorted(by: { $0.key.sortIndex < $1.key.sortIndex }) {
            let label = stem.displayName.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespaces)
            var url = folder.appendingPathComponent("\(safeBase) - \(label).wav")
            var n = 2
            // Never overwrite a previous split of the same file (older tracks may still reference it).
            while fm.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(safeBase) - \(label) \(n).wav"); n += 1
            }
            try AudioFileIO.writeWAV(audio, to: url, format: .int24)
            out[stem] = url
        }
        return out
    }
}
