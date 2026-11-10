import Foundation
import SFCore

/// Stems that StudioForge can produce.
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
}

public struct SeparationOptions {
    public var stems: Set<Stem>
    /// Split the drum stem further into kick / snare / toms / hi-hat / cymbals.
    public var splitDrums: Bool
    public init(stems: Set<Stem> = [.vocals, .bass, .drums, .guitar, .other], splitDrums: Bool = true) {
        self.stems = stems; self.splitDrums = splitDrums
    }
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
        for (stem, audio) in stems {
            let url = folder.appendingPathComponent("\(baseName) - \(stem.displayName.replacingOccurrences(of: "/", with: "-")).wav")
            try AudioFileIO.writeWAV(audio, to: url, format: .int24)
            out[stem] = url
        }
        return out
    }
}
