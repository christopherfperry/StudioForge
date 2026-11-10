import Foundation

/// Portable WAV / AIFF reading and writing (PCM 16/24/32-bit and 32-bit float).
/// Compressed formats are handled by platform encoders/decoders (AVFoundation, ffmpeg).
public enum AudioSampleFormat: String, Codable, CaseIterable {
    case int16, int24, int32, float32
    public var bitsPerSample: Int { switch self { case .int16: return 16; case .int24: return 24; case .int32, .float32: return 32 } }
    public var bytesPerSample: Int { bitsPerSample / 8 }
    public var isFloat: Bool { self == .float32 }
}

public enum AudioFileIO {

    // MARK: Reading

    public static func read(_ url: URL) throws -> AudioData {
        let data = try Data(contentsOf: url)
        guard data.count >= 12 else { throw StudioForgeError.unsupportedFormat(url.lastPathComponent) }
        let tag = String(decoding: data[0..<4], as: UTF8.self)
        if tag == "RIFF" || tag == "RF64" { return try readWAV(data) }
        if tag == "FORM" { return try readAIFF(data) }
        throw StudioForgeError.unsupportedFormat(url.pathExtension)
    }

    private static func le16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func le32(_ d: Data, _ o: Int) -> Int { le16(d, o) | le16(d, o + 2) << 16 }
    private static func be16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) << 8 | Int(d[d.startIndex + o + 1]) }
    private static func be32(_ d: Data, _ o: Int) -> Int { be16(d, o) << 16 | be16(d, o + 2) }

    static func readWAV(_ d: Data) throws -> AudioData {
        var pos = 12
        var channels = 0, sampleRate = 0, bits = 0, formatTag = 0
        var dataStart = -1, dataLen = 0
        while pos + 8 <= d.count {
            let id = String(decoding: d[d.startIndex + pos..<d.startIndex + pos + 4], as: UTF8.self)
            var len = le32(d, pos + 4)
            if id == "fmt " {
                formatTag = le16(d, pos + 8)
                channels = le16(d, pos + 10)
                sampleRate = le32(d, pos + 12)
                bits = le16(d, pos + 22)
                if formatTag == 0xFFFE && len >= 40 { formatTag = le16(d, pos + 32) } // WAVE_FORMAT_EXTENSIBLE
            } else if id == "data" {
                dataStart = pos + 8
                if len == 0 || len == 0xFFFF_FFFF || dataStart + len > d.count { len = d.count - dataStart }
                dataLen = len
                break
            }
            pos += 8 + len + (len & 1)
        }
        guard channels > 0, dataStart >= 0, [16, 24, 32].contains(bits) || (bits == 64 && formatTag == 3) else {
            throw StudioForgeError.unsupportedFormat("WAV (\(bits)-bit, format \(formatTag))")
        }
        let isFloat = formatTag == 3
        let bps = bits / 8
        let frames = dataLen / (bps * channels)
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: dataStart)
            for f in 0..<frames {
                for c in 0..<channels {
                    let p = base.advanced(by: (f * channels + c) * bps)
                    out[c][f] = decodeSample(p, bits: bits, isFloat: isFloat, bigEndian: false)
                }
            }
        }
        return AudioData(channels: out, sampleRate: Double(sampleRate))
    }

    static func readAIFF(_ d: Data) throws -> AudioData {
        let formType = String(decoding: d[d.startIndex + 8..<d.startIndex + 12], as: UTF8.self)
        guard formType == "AIFF" || formType == "AIFC" else { throw StudioForgeError.unsupportedFormat("AIFF variant") }
        var pos = 12
        var channels = 0, frames = 0, bits = 0, sampleRate = 0.0, ssndStart = -1
        var isFloat = false, littleEndian = false
        while pos + 8 <= d.count {
            let id = String(decoding: d[d.startIndex + pos..<d.startIndex + pos + 4], as: UTF8.self)
            let len = be32(d, pos + 4)
            if id == "COMM" {
                channels = be16(d, pos + 8)
                frames = be32(d, pos + 10)
                bits = be16(d, pos + 14)
                sampleRate = readExtended(d, pos + 16)
                if formType == "AIFC" && len >= 22 {
                    let comp = String(decoding: d[d.startIndex + pos + 26..<d.startIndex + pos + 30], as: UTF8.self)
                    if comp == "fl32" || comp == "FL32" { isFloat = true }
                    else if comp == "sowt" { littleEndian = true }
                    else if comp != "NONE" { throw StudioForgeError.unsupportedFormat("AIFC \(comp)") }
                }
            } else if id == "SSND" {
                let offset = be32(d, pos + 8)
                ssndStart = pos + 16 + offset
            }
            pos += 8 + len + (len & 1)
        }
        guard channels > 0, ssndStart >= 0, [16, 24, 32].contains(bits) else { throw StudioForgeError.unsupportedFormat("AIFF \(bits)-bit") }
        let bps = bits / 8
        let available = (d.count - ssndStart) / (bps * channels)
        let n = min(frames, available)
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: channels)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: ssndStart)
            for f in 0..<n {
                for c in 0..<channels {
                    out[c][f] = decodeSample(base.advanced(by: (f * channels + c) * bps), bits: bits, isFloat: isFloat, bigEndian: !littleEndian)
                }
            }
        }
        return AudioData(channels: out, sampleRate: sampleRate)
    }

    @inline(__always)
    private static func decodeSample(_ p: UnsafeRawPointer, bits: Int, isFloat: Bool, bigEndian: Bool) -> Float {
        func byte(_ i: Int) -> UInt32 { UInt32(p.load(fromByteOffset: i, as: UInt8.self)) }
        switch bits {
        case 16:
            let v = bigEndian ? (byte(0) << 8 | byte(1)) : (byte(1) << 8 | byte(0))
            return Float(Int16(truncatingIfNeeded: v)) / 32768
        case 24:
            let v = bigEndian ? (byte(0) << 16 | byte(1) << 8 | byte(2)) : (byte(2) << 16 | byte(1) << 8 | byte(0))
            let s = Int32(bitPattern: v << 8) >> 8
            return Float(s) / 8_388_608
        case 32:
            let v = bigEndian ? (byte(0) << 24 | byte(1) << 16 | byte(2) << 8 | byte(3))
                              : (byte(3) << 24 | byte(2) << 16 | byte(1) << 8 | byte(0))
            return isFloat ? Float(bitPattern: v) : Float(Double(Int32(bitPattern: v)) / 2_147_483_648.0)
        case 64:
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(p.load(fromByteOffset: i, as: UInt8.self)) << (8 * UInt64(i)) }
            return Float(Double(bitPattern: v))
        default: return 0
        }
    }

    /// 80-bit IEEE extended (AIFF sample rate).
    private static func readExtended(_ d: Data, _ o: Int) -> Double {
        let exp = be16(d, o) & 0x7FFF
        let sign = (be16(d, o) & 0x8000) != 0 ? -1.0 : 1.0
        var mant: UInt64 = 0
        for i in 0..<8 { mant = (mant << 8) | UInt64(d[d.startIndex + o + 2 + i]) }
        if exp == 0 && mant == 0 { return 0 }
        return sign * Double(mant) * pow(2, Double(exp - 16383 - 63))
    }

    private static func extended(_ value: Double) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 10)
        guard value > 0 else { return bytes }
        var exp = Int(floor(log2(value)))
        var mant = UInt64(value / pow(2, Double(exp - 63)))
        if mant & (1 << 63) == 0 { mant <<= 1; exp -= 1 }
        let e = UInt16(exp + 16383)
        bytes[0] = UInt8(e >> 8); bytes[1] = UInt8(e & 0xFF)
        for i in 0..<8 { bytes[2 + i] = UInt8((mant >> (56 - 8 * UInt64(i))) & 0xFF) }
        return bytes
    }

    // MARK: Writing

    /// Writes interleaved/planar float audio as WAV. Values are clipped to [-1, 1] for integer formats.
    public static func writeWAV(_ audio: AudioData, to url: URL, format: AudioSampleFormat = .int24) throws {
        let w = try StreamingWAVWriter(url: url, sampleRate: audio.sampleRate, channels: audio.channelCount, format: format)
        try w.append(planar: audio.channels)
        try w.finish()
    }

    public static func writeAIFF(_ audio: AudioData, to url: URL, format: AudioSampleFormat = .int24) throws {
        let ch = audio.channelCount, frames = audio.frameCount
        let fmt: AudioSampleFormat = format == .float32 ? .int32 : format  // plain AIFF has no float
        let bps = fmt.bytesPerSample
        var out = Data()
        func be32(_ v: Int) { out.append(contentsOf: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        func be16(_ v: Int) { out.append(contentsOf: [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        let ssndLen = 8 + frames * ch * bps
        out.append(contentsOf: Array("FORM".utf8)); be32(4 + 26 + 8 + ssndLen)
        out.append(contentsOf: Array("AIFF".utf8))
        out.append(contentsOf: Array("COMM".utf8)); be32(18); be16(ch); be32(frames); be16(fmt.bitsPerSample)
        out.append(contentsOf: extended(audio.sampleRate))
        out.append(contentsOf: Array("SSND".utf8)); be32(ssndLen); be32(0); be32(0)
        out.reserveCapacity(out.count + frames * ch * bps)
        for f in 0..<frames {
            for c in 0..<ch {
                let s = clampf(audio.channels[c][f], -1, 1)
                switch fmt {
                case .int16: be16(Int(Int16(clamping: Int((s * 32767).rounded()))) & 0xFFFF)
                case .int24:
                    let v = Int((s * 8_388_607).rounded())
                    out.append(contentsOf: [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
                default: be32(Int(Int32(clamping: Int64((Double(s) * 2_147_483_647).rounded()))) & 0xFFFF_FFFF)
                }
            }
        }
        try out.write(to: url, options: .atomic)
    }
}

/// Incremental WAV writer used by the recorder's disk thread (never called on the audio thread).
public final class StreamingWAVWriter {
    public let url: URL
    public let sampleRate: Double
    public let channels: Int
    public let format: AudioSampleFormat
    private let handle: FileHandle
    private var framesWritten = 0
    private var scratch = Data()

    public init(url: URL, sampleRate: Double, channels: Int, format: AudioSampleFormat) throws {
        self.url = url; self.sampleRate = sampleRate; self.channels = channels; self.format = format
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: url.path) else { throw StudioForgeError.io("Cannot create \(url.path)") }
        handle = h
        handle.write(header(dataBytes: 0))
    }

    public var frameCount: Int { framesWritten }

    private func header(dataBytes: Int) -> Data {
        var d = Data()
        func le32(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func le16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        let bps = format.bytesPerSample
        d.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16)
        le16(format.isFloat ? 3 : 1); le16(channels); le32(Int(sampleRate))
        le32(Int(sampleRate) * channels * bps); le16(channels * bps); le16(format.bitsPerSample)
        d.append(contentsOf: Array("data".utf8)); le32(dataBytes)
        return d
    }

    /// Appends interleaved samples.
    public func append(interleaved p: UnsafePointer<Float>, frames: Int) throws {
        scratch.removeAll(keepingCapacity: true)
        let n = frames * channels
        scratch.reserveCapacity(n * format.bytesPerSample)
        for i in 0..<n { encode(p[i]) }
        handle.write(scratch)
        framesWritten += frames
    }

    public func append(planar: [[Float]]) throws {
        guard let frames = planar.first?.count else { return }
        let chunk = 16384
        var start = 0
        var inter = [Float](repeating: 0, count: chunk * channels)
        while start < frames {
            let n = min(chunk, frames - start)
            for f in 0..<n { for c in 0..<channels { inter[f * channels + c] = planar[min(c, planar.count - 1)][start + f] } }
            try inter.withUnsafeBufferPointer { try append(interleaved: $0.baseAddress!, frames: n) }
            start += n
        }
    }

    @inline(__always) private func encode(_ x: Float) {
        switch format {
        case .float32:
            let b = x.bitPattern
            scratch.append(contentsOf: [UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF), UInt8((b >> 16) & 0xFF), UInt8(b >> 24)])
        case .int16:
            let v = UInt16(bitPattern: Int16(clamping: Int((clampf(x, -1, 1) * 32767).rounded())))
            scratch.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)])
        case .int24:
            let v = Int32((clampf(x, -1, 1) * 8_388_607).rounded())
            let u = UInt32(bitPattern: v)
            scratch.append(contentsOf: [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF)])
        case .int32:
            let v = UInt32(bitPattern: Int32(clamping: Int64((Double(clampf(x, -1, 1)) * 2_147_483_647).rounded())))
            scratch.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
        }
    }

    /// Patches the header with final sizes and closes the file.
    public func finish() throws {
        let bytes = framesWritten * channels * format.bytesPerSample
        handle.seek(toFileOffset: 0)
        handle.write(header(dataBytes: bytes))
        handle.closeFile()
    }
}

// MARK: - Dither & resampling (offline)

public enum Dither {
    /// TPDF dither to the given bit depth (applied before integer quantisation).
    public static func tpdf(_ audio: inout AudioData, bits: Int, seed: UInt64 = 1) {
        guard bits < 32 else { return }
        var rng = SplitMix64(seed: seed)
        let lsb = Float(1.0 / pow(2.0, Double(bits - 1)))
        for c in 0..<audio.channels.count {
            for i in 0..<audio.channels[c].count {
                let r = Float(rng.unit() - rng.unit())
                audio.channels[c][i] += r * lsb
            }
        }
    }
}

public enum Resampler {
    /// Windowed-sinc (Blackman, 32 zero crossings) sample-rate conversion. Offline quality.
    public static func resample(_ x: [Float], from srcRate: Double, to dstRate: Double, zeroCrossings: Int = 32) -> [Float] {
        if abs(srcRate - dstRate) < 0.5 || x.isEmpty { return x }
        let ratio = dstRate / srcRate
        let outCount = Int((Double(x.count) * ratio).rounded())
        let cutoff = min(1.0, ratio) * 0.97
        var y = [Float](repeating: 0, count: outCount)
        let zc = Double(zeroCrossings)
        let halfWidth = zc / cutoff
        for n in 0..<outCount {
            let t = Double(n) / ratio
            let center = Int(t)
            let lo = max(0, center - Int(halfWidth)), hi = min(x.count - 1, center + Int(halfWidth) + 1)
            var acc = 0.0
            if lo <= hi {
                for k in lo...hi {
                    let d = (t - Double(k)) * cutoff
                    if abs(d) >= zc { continue }
                    let sinc = d == 0 ? 1.0 : sin(Double.pi * d) / (Double.pi * d)
                    let w = 0.42 + 0.5 * cos(Double.pi * d / zc) + 0.08 * cos(2 * Double.pi * d / zc)
                    acc += Double(x[k]) * sinc * w * cutoff
                }
            }
            y[n] = Float(acc)
        }
        return y
    }

    public static func resample(_ a: AudioData, to rate: Double) -> AudioData {
        if abs(a.sampleRate - rate) < 0.5 { return a }
        return AudioData(channels: a.channels.map { resample($0, from: a.sampleRate, to: rate) }, sampleRate: rate)
    }
}
