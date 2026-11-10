import Foundation
import SFCore

/// Output file formats offered in the export sheet.
public enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case wav, aiff, flac, mp3, aac, alac, caf, ogg

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .flac: return "FLAC"
        case .mp3: return "MP3"
        case .aac: return "AAC (M4A)"
        case .alac: return "Apple Lossless (ALAC)"
        case .caf: return "Core Audio (CAF)"
        case .ogg: return "Ogg Vorbis"
        }
    }

    public var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .flac: return "flac"
        case .mp3: return "mp3"
        case .aac, .alac: return "m4a"
        case .caf: return "caf"
        case .ogg: return "ogg"
        }
    }

    /// Lossy codecs use a bitrate instead of a bit depth.
    public var isLossy: Bool { self == .mp3 || self == .aac || self == .ogg }

    /// Bit depths that make sense for the format.
    public var supportedSampleFormats: [AudioSampleFormat] {
        switch self {
        case .wav, .caf: return [.int16, .int24, .int32, .float32]
        case .aiff: return [.int16, .int24, .int32]
        case .flac, .alac: return [.int16, .int24]
        case .mp3, .aac, .ogg: return []
        }
    }

    /// Short note shown in the UI about what is needed to write this format.
    public var requirementNote: String? {
        switch self {
        case .mp3, .ogg: return "Requires ffmpeg (brew install ffmpeg) or a bundled ffmpeg binary."
        case .flac, .aac, .alac, .caf: return "Uses Apple's encoders on macOS (falls back to ffmpeg if present)."
        default: return nil
        }
    }
}

public enum ExportRange: Codable, Hashable {
    /// From 0 to the end of the last clip.
    case wholeProject
    /// The project's loop region.
    case loop
    case custom(start: Double, end: Double)
}

public enum ExportContent: String, Codable, CaseIterable {
    case master, stems, masterAndStems
    public var displayName: String {
        switch self {
        case .master: return "Master mixdown"
        case .stems: return "Stems (every track)"
        case .masterAndStems: return "Master + stems"
        }
    }
}

public struct ExportSettings: Codable, Hashable {
    public var format: ExportFormat = .wav
    public var sampleFormat: AudioSampleFormat = .int24
    /// nil = project sample rate.
    public var sampleRate: Double?
    public var dither = true
    public var normalize = false
    /// Peak target (dBFS) used when `normalize` is on.
    public var normalizePeakDB: Float = -1
    public var content: ExportContent = .master
    public var range: ExportRange = .wholeProject
    public var tailSeconds: Double = 2
    /// Run stems through the master insert chain too.
    public var stemsThroughMaster = false
    /// Lossy bitrate (MP3/AAC/OGG).
    public var bitrateKbps = 256
    /// Also write a Standard MIDI File of all instrument/drum tracks next to the audio.
    public var includeMIDI = false

    public init() {}

    public static let sampleRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    /// Effective integer bit depth used for dithering (nil for float/lossy).
    public var ditherBits: Int? {
        guard dither, !format.isLossy else { return nil }
        let fmt = effectiveSampleFormat
        return fmt.isFloat || fmt == .int32 ? nil : fmt.bitsPerSample
    }

    /// Sample format clamped to what the format supports.
    public var effectiveSampleFormat: AudioSampleFormat {
        let supported = format.supportedSampleFormats
        if supported.isEmpty { return .float32 }
        return supported.contains(sampleFormat) ? sampleFormat : (supported.contains(.int24) ? .int24 : supported[0])
    }
}
