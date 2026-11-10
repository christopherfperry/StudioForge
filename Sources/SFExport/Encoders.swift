import Foundation
import SFCore

/// Writes rendered audio to a file. Encoders are looked up per format in `AudioEncoders`; add a
/// new format by registering another encoder (see docs/EXTENDING.md).
public protocol AudioEncoder {
    var name: String { get }
    func canEncode(_ format: ExportFormat) -> Bool
    func encode(_ audio: AudioData, to url: URL, settings: ExportSettings) throws
}

public enum AudioEncoders {
    private static let lock = NSLock()
    private static var registered: [AudioEncoder] = defaultEncoders()

    static func defaultEncoders() -> [AudioEncoder] {
        var list: [AudioEncoder] = [PCMFileEncoder()]
        #if os(macOS)
        list.append(AppleAudioEncoder())
        #endif
        list.append(FFmpegEncoder())
        return list
    }

    /// Registers an encoder with priority over the built-in ones.
    public static func register(_ encoder: AudioEncoder) {
        lock.lock(); registered.insert(encoder, at: 0); lock.unlock()
    }

    public static func encoders(for format: ExportFormat) -> [AudioEncoder] {
        lock.lock(); defer { lock.unlock() }
        return registered.filter { $0.canEncode(format) }
    }

    /// Whether any encoder is currently able to write the format (ffmpeg availability is checked).
    public static func isAvailable(_ format: ExportFormat) -> Bool {
        encoders(for: format).contains { enc in
            if enc is FFmpegEncoder { return FFmpegLocator.find() != nil }
            return true
        }
    }

    /// Tries each capable encoder in order; returns the name of the encoder that succeeded.
    @discardableResult
    public static func encode(_ audio: AudioData, to url: URL, settings: ExportSettings) throws -> String {
        let candidates = encoders(for: settings.format)
        guard !candidates.isEmpty else {
            throw StudioForgeError.unsupportedFormat("No encoder for \(settings.format.displayName).")
        }
        var errors: [String] = []
        for enc in candidates {
            do {
                try enc.encode(audio, to: url, settings: settings)
                return enc.name
            } catch {
                errors.append("\(enc.name): \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        throw StudioForgeError.io("Could not write \(settings.format.displayName). " + errors.joined(separator: " | "))
    }
}

/// Portable WAV / AIFF writer (pure Swift, works everywhere).
public struct PCMFileEncoder: AudioEncoder {
    public init() {}
    public var name: String { "Built-in PCM" }
    public func canEncode(_ format: ExportFormat) -> Bool { format == .wav || format == .aiff }
    public func encode(_ audio: AudioData, to url: URL, settings: ExportSettings) throws {
        switch settings.format {
        case .wav: try AudioFileIO.writeWAV(audio, to: url, format: settings.effectiveSampleFormat)
        case .aiff: try AudioFileIO.writeAIFF(audio, to: url, format: settings.effectiveSampleFormat)
        default: throw StudioForgeError.unsupportedFormat(settings.format.displayName)
        }
    }
}

/// Finds an ffmpeg executable: user override (UserDefaults "SFFFmpegPath"), a binary bundled in
/// the app's Resources, Homebrew locations, then $PATH.
public enum FFmpegLocator {
    public static let userDefaultsKey = "SFFFmpegPath"

    public static func find() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let custom = UserDefaults.standard.string(forKey: userDefaultsKey), !custom.isEmpty { candidates.append(custom) }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path { candidates.append(res) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/ffmpeg" }
        }
        for c in candidates where fm.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        return nil
    }
}

/// Encodes through an external ffmpeg process: renders a temporary 32-bit float WAV, then converts.
/// Used for MP3 / OGG, and as a fallback for FLAC / AAC / ALAC / CAF.
public struct FFmpegEncoder: AudioEncoder {
    public init() {}
    public var name: String { "ffmpeg" }
    public func canEncode(_ format: ExportFormat) -> Bool { format != .wav && format != .aiff }

    public func codecArguments(_ s: ExportSettings) -> [String] {
        let bits = s.effectiveSampleFormat
        switch s.format {
        case .mp3: return ["-c:a", "libmp3lame", "-b:a", "\(s.bitrateKbps)k"]
        case .ogg: return ["-c:a", "libvorbis", "-b:a", "\(s.bitrateKbps)k"]
        case .aac: return ["-c:a", "aac", "-b:a", "\(s.bitrateKbps)k"]
        case .flac: return ["-c:a", "flac", "-sample_fmt", bits == .int16 ? "s16" : "s32"] + (bits == .int16 ? [] : ["-bits_per_raw_sample", "24"])
        case .alac: return ["-c:a", "alac", "-sample_fmt", bits == .int16 ? "s16p" : "s32p"]
        case .caf:
            let codec: String
            switch bits {
            case .int16: codec = "pcm_s16be"
            case .int24: codec = "pcm_s24be"
            case .int32: codec = "pcm_s32be"
            case .float32: codec = "pcm_f32be"
            }
            return ["-c:a", codec]
        case .wav, .aiff: return []
        }
    }

    public func encode(_ audio: AudioData, to url: URL, settings: ExportSettings) throws {
        guard let ffmpeg = FFmpegLocator.find() else {
            throw StudioForgeError.unsupportedFormat("\(settings.format.displayName) needs ffmpeg. Install it with Homebrew (brew install ffmpeg) or set its path in Settings.")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sf-export-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try AudioFileIO.writeWAV(audio, to: tmp, format: .float32)
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", tmp.path] + codecArguments(settings) + [url.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw StudioForgeError.io("ffmpeg failed (\(p.terminationStatus)): \(msg)")
        }
    }
}
