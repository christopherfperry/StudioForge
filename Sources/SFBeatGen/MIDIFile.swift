import Foundation
import SFCore

/// Standard MIDI File (type 1) writer and a minimal reader for note data.
public enum MIDIFile {
    public struct Track {
        public var name: String
        public var channel: Int // 0-15 (9 = GM drums)
        public var notes: [MIDINote]
        public var program: Int?
        public init(name: String, channel: Int, notes: [MIDINote], program: Int? = nil) {
            self.name = name; self.channel = channel; self.notes = notes; self.program = program
        }
    }

    public static let ppq = 480

    public static func data(tracks: [Track], tempo: Double, timeSignature: TimeSignature = TimeSignature(4, 4)) -> Data {
        var out = Data()
        out.append(contentsOf: Array("MThd".utf8))
        out.append(be32(6)); out.append(be16(1)); out.append(be16(UInt16(tracks.count + 1))); out.append(be16(UInt16(ppq)))

        // Conductor track: tempo + time signature.
        var t0 = Data()
        t0.append(vlq(0)); t0.append(contentsOf: [0xFF, 0x03]); appendText(&t0, "StudioForge")
        let usPerQuarter = UInt32(max(1, min(16_777_215, (60_000_000 / max(1, tempo)).rounded())))
        t0.append(vlq(0)); t0.append(contentsOf: [0xFF, 0x51, 0x03, UInt8((usPerQuarter >> 16) & 0xFF), UInt8((usPerQuarter >> 8) & 0xFF), UInt8(usPerQuarter & 0xFF)])
        let dd = UInt8(max(0, Int(log2(Double(max(1, timeSignature.denominator))).rounded())))
        t0.append(vlq(0)); t0.append(contentsOf: [0xFF, 0x58, 0x04, UInt8(clamping: timeSignature.numerator), dd, 24, 8])
        t0.append(vlq(0)); t0.append(contentsOf: [0xFF, 0x2F, 0x00])
        appendChunk(&out, t0)

        for tr in tracks {
            var d = Data()
            d.append(vlq(0)); d.append(contentsOf: [0xFF, 0x03]); appendText(&d, tr.name)
            let ch = UInt8(max(0, min(15, tr.channel)))
            if let p = tr.program { d.append(vlq(0)); d.append(contentsOf: [0xC0 | ch, UInt8(max(0, min(127, p)))]) }
            // Build absolute-tick events; note-offs sort before note-ons at equal ticks.
            var events: [(tick: Int, order: Int, bytes: [UInt8])] = []
            for n in tr.notes {
                let on = max(0, Int((n.startBeat * Double(ppq)).rounded()))
                let off = max(on + 1, Int(((n.startBeat + max(0.001, n.durationBeats)) * Double(ppq)).rounded()))
                let pitch = UInt8(max(0, min(127, n.pitch))), vel = UInt8(max(1, min(127, n.velocity)))
                events.append((on, 1, [0x90 | ch, pitch, vel]))
                events.append((off, 0, [0x80 | ch, pitch, 0]))
            }
            events.sort { ($0.tick, $0.order) < ($1.tick, $1.order) }
            var last = 0
            for e in events { d.append(vlq(UInt32(e.tick - last))); d.append(contentsOf: e.bytes); last = e.tick }
            d.append(vlq(0)); d.append(contentsOf: [0xFF, 0x2F, 0x00])
            appendChunk(&out, d)
        }
        return out
    }

    public static func write(tracks: [Track], tempo: Double, timeSignature: TimeSignature = TimeSignature(4, 4), to url: URL) throws {
        try data(tracks: tracks, tempo: tempo, timeSignature: timeSignature).write(to: url, options: .atomic)
    }

    /// Parses note on/off pairs from an SMF (type 0 or 1). Returns tracks (channel taken from the
    /// first note event), the first tempo found (default 120) and the PPQ-independent beat positions.
    public static func read(_ data: Data) throws -> (tracks: [Track], tempo: Double) {
        let b = [UInt8](data)
        var pos = 0
        func u32() throws -> UInt32 {
            guard pos + 4 <= b.count else { throw StudioForgeError.invalid("Truncated MIDI file") }
            defer { pos += 4 }
            return UInt32(b[pos]) << 24 | UInt32(b[pos + 1]) << 16 | UInt32(b[pos + 2]) << 8 | UInt32(b[pos + 3])
        }
        func u16() throws -> Int {
            guard pos + 2 <= b.count else { throw StudioForgeError.invalid("Truncated MIDI file") }
            defer { pos += 2 }
            return Int(b[pos]) << 8 | Int(b[pos + 1])
        }
        guard b.count >= 14, String(bytes: b[0..<4], encoding: .ascii) == "MThd" else { throw StudioForgeError.invalid("Not a MIDI file") }
        pos = 4
        let hlen = Int(try u32()); _ = try u16(); let ntrks = try u16(); let division = try u16()
        pos = 8 + hlen
        guard division & 0x8000 == 0, division > 0 else { throw StudioForgeError.unsupportedFormat("SMPTE-timed MIDI files are not supported") }
        var tempo = 120.0
        var tracks: [Track] = []
        for ti in 0..<ntrks {
            guard pos + 8 <= b.count else { break }
            let id = String(bytes: b[pos..<(pos + 4)], encoding: .ascii); pos += 4
            let len = Int(try u32())
            let end = min(b.count, pos + len)
            guard id == "MTrk" else { pos = end; continue }
            var tick = 0, running: UInt8 = 0
            var name = "Track \(ti + 1)", channel = -1
            var open: [Int: (Int, Int)] = [:] // key = ch*128+pitch -> (startTick, vel)
            var notes: [MIDINote] = []
            func readVLQ() -> Int {
                var v = 0
                while pos < end { let c = b[pos]; pos += 1; v = (v << 7) | Int(c & 0x7F); if c & 0x80 == 0 { break } }
                return v
            }
            while pos < end {
                tick += readVLQ()
                guard pos < end else { break }
                var status = b[pos]
                if status & 0x80 != 0 { pos += 1; if status < 0xF0 { running = status } } else { status = running }
                if status == 0xFF {
                    guard pos < end else { break }
                    let type = b[pos]; pos += 1
                    let l = readVLQ()
                    let payload = Array(b[pos..<min(end, pos + l)]); pos += l
                    if type == 0x51, payload.count == 3 {
                        let us = Int(payload[0]) << 16 | Int(payload[1]) << 8 | Int(payload[2])
                        if us > 0 && tempo == 120.0 { tempo = 60_000_000 / Double(us) }
                    } else if type == 0x03, let s = String(bytes: payload, encoding: .utf8), !s.isEmpty { name = s }
                } else if status == 0xF0 || status == 0xF7 {
                    pos += readVLQ()
                } else {
                    let kind = status & 0xF0, ch = Int(status & 0x0F)
                    let needs2 = !(kind == 0xC0 || kind == 0xD0)
                    guard pos + (needs2 ? 1 : 0) < end else { break }
                    let d1 = Int(b[pos]); let d2 = needs2 ? Int(b[pos + 1]) : 0
                    pos += needs2 ? 2 : 1
                    if kind == 0x90 && d2 > 0 {
                        open[ch * 128 + d1] = (tick, d2); if channel < 0 { channel = ch }
                    } else if kind == 0x80 || (kind == 0x90 && d2 == 0) {
                        if let (st, v) = open.removeValue(forKey: ch * 128 + d1) {
                            notes.append(MIDINote(pitch: d1, velocity: v, startBeat: Double(st) / Double(division),
                                                  durationBeats: Double(max(1, tick - st)) / Double(division)))
                        }
                    }
                }
            }
            pos = end
            if !notes.isEmpty { tracks.append(Track(name: name, channel: max(0, channel), notes: notes.sorted { $0.startBeat < $1.startBeat })) }
        }
        return (tracks, tempo)
    }

    // MARK: helpers
    static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    static func vlq(_ value: UInt32) -> Data {
        var v = value
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return Data(bytes)
    }
    static func appendText(_ d: inout Data, _ s: String) {
        let bytes = Array(s.utf8.prefix(127)); d.append(vlq(UInt32(bytes.count))); d.append(contentsOf: bytes)
    }
    static func appendChunk(_ out: inout Data, _ body: Data) {
        out.append(contentsOf: Array("MTrk".utf8)); out.append(be32(UInt32(body.count))); out.append(body)
    }
}
