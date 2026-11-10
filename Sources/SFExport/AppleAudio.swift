#if os(macOS)
import Foundation
import AVFoundation
import SFCore

/// FLAC / AAC / ALAC / CAF writer using Apple's encoders through AVAudioFile.
public struct AppleAudioEncoder: AudioEncoder {
    public init() {}
    public var name: String { "Apple AVAudioFile" }
    public func canEncode(_ format: ExportFormat) -> Bool { [.flac, .aac, .alac, .caf].contains(format) }

    func fileSettings(_ s: ExportSettings, sampleRate: Double, channels: Int) -> [String: Any] {
        var d: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        let bits = s.effectiveSampleFormat.bitsPerSample
        switch s.format {
        case .flac:
            d[AVFormatIDKey] = Int(kAudioFormatFLAC)
            d[AVEncoderBitDepthHintKey] = bits
        case .alac:
            d[AVFormatIDKey] = Int(kAudioFormatAppleLossless)
            d[AVEncoderBitDepthHintKey] = bits
        case .aac:
            d[AVFormatIDKey] = Int(kAudioFormatMPEG4AAC)
            d[AVEncoderBitRateKey] = s.bitrateKbps * 1000
        case .caf:
            d[AVFormatIDKey] = Int(kAudioFormatLinearPCM)
            d[AVLinearPCMBitDepthKey] = bits
            d[AVLinearPCMIsFloatKey] = s.effectiveSampleFormat.isFloat
            d[AVLinearPCMIsBigEndianKey] = false
            d[AVLinearPCMIsNonInterleaved] = false
        default: break
        }
        return d
    }

    public func encode(_ audio: AudioData, to url: URL, settings: ExportSettings) throws {
        var a = audio
        // The AAC encoder supports up to 48 kHz.
        if settings.format == .aac && a.sampleRate > 48_000 { a = Resampler.resample(a, to: 48_000) }
        try write(a, url: url, settings: fileSettings(settings, sampleRate: a.sampleRate, channels: a.channelCount))
    }

    /// Separate function so the AVAudioFile is released (and the file finalised) on return.
    private func write(_ audio: AudioData, url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
              let dst = buffer.floatChannelData else { throw StudioForgeError.io("Could not allocate an audio buffer.") }
        let channels = Int(file.processingFormat.channelCount)
        var pos = 0
        let total = audio.frameCount
        while pos < total {
            let n = min(Int(chunk), total - pos)
            for c in 0..<channels {
                let src = audio.channels[min(c, audio.channelCount - 1)]
                src.withUnsafeBufferPointer { sp in
                    (dst[c]).update(from: sp.baseAddress! + pos, count: n)
                }
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            pos += n
        }
    }
}

/// Registers an AVFoundation decoder so MP3 / AAC / M4A / FLAC / ALAC / CAF files can be imported.
public enum AppleAudioDecoding {
    private static var registered = false
    public static func register() {
        guard !registered else { return }
        registered = true
        AudioDecoding.register { url in
            let ext = url.pathExtension.lowercased()
            if ext == "wav" || ext == "wave" || ext == "aif" || ext == "aiff" {
                // Prefer the portable reader for plain PCM (handles 24-bit packed etc.).
                if let a = try? AudioFileIO.read(url) { return a }
            }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(file.length)
            let format = file.processingFormat
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                return AudioData(channels: [[]], sampleRate: format.sampleRate)
            }
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            var channels: [[Float]] = []
            if let data = buf.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    channels.append(Array(UnsafeBufferPointer(start: data[c], count: n)))
                }
            }
            return AudioData(channels: channels, sampleRate: format.sampleRate)
        }
    }
}
#endif
