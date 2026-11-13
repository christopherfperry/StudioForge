import Foundation
import SFCore

/// A recording pass. The audio thread pushes samples into lock-free rings; a background disk
/// thread drains them into WAV files. The DRY input is always captured ("record clean");
/// the processed (wet) track signal is captured additionally when the track asks for it.
public final class RecordSession: @unchecked Sendable {
    public final class Lane: @unchecked Sendable {
        public let trackID: UUID
        public let channels: Int
        public let inputFirst: Int
        let dry: SPSCRingBuffer
        let wet: SPSCRingBuffer?
        /// Timeline frame of the first captured sample (Int.min until capture starts).
        public let firstFrame = AtomicInt(Int.min)
        public let framesCaptured = AtomicInt(0)
        public let overflow = AtomicBool(false)
        let dryURL: URL
        let wetURL: URL?

        init(trackID: UUID, channels: Int, inputFirst: Int, captureWet: Bool, sampleRate: Double, dryURL: URL, wetURL: URL?) {
            self.trackID = trackID; self.channels = channels; self.inputFirst = inputFirst
            let seconds = 10.0
            dry = SPSCRingBuffer(minimumCapacity: Int(sampleRate * seconds) * channels)
            wet = captureWet ? SPSCRingBuffer(minimumCapacity: Int(sampleRate * seconds) * 2) : nil
            self.dryURL = dryURL
            self.wetURL = captureWet ? wetURL : nil
        }
    }

    public let lanes: [Lane]
    /// Capture window on the timeline (frames). `captureEnd == Int.max` means open-ended.
    public let captureStart: Int
    public let captureEnd: Int
    public let sampleRate: Double

    public init(lanes: [Lane], captureStart: Int, captureEnd: Int, sampleRate: Double) {
        self.lanes = lanes; self.captureStart = captureStart; self.captureEnd = captureEnd; self.sampleRate = sampleRate
    }

    public static let empty = RecordSession(lanes: [], captureStart: 0, captureEnd: 0, sampleRate: 48_000)

    @inline(__always) func lane(for id: UUID) -> Lane? {
        for l in lanes where l.trackID == id { return l }
        return nil
    }
}

/// Description of an armed track for `Recorder.begin`.
public struct RecordRequest {
    public var trackID: UUID
    public var trackName: String
    public var inputFirst: Int
    public var channels: Int
    public var captureWet: Bool
    public init(trackID: UUID, trackName: String, inputFirst: Int, channels: Int, captureWet: Bool) {
        self.trackID = trackID; self.trackName = trackName; self.inputFirst = inputFirst
        self.channels = channels; self.captureWet = captureWet
    }
}

/// Result of a finished recording for one track.
public struct RecordedTake {
    public var trackID: UUID
    public var dryURL: URL
    public var wetURL: URL?
    /// Timeline frame of the first sample (before latency compensation).
    public var startFrame: Int
    public var frames: Int
    public var sampleRate: Double
    public var hadOverflow: Bool
}

/// Owns the disk-writer thread for a RecordSession.
public final class Recorder: @unchecked Sendable {
    public private(set) var session: RecordSession?
    private var writers: [(lane: RecordSession.Lane, dry: StreamingWAVWriter, wet: StreamingWAVWriter?)] = []
    private var thread: Thread?
    private let running = AtomicBool(false)
    private let finished = DispatchSemaphore(value: 0)
    public private(set) var lastError: String?

    public init() {}

    /// Creates files and rings for the armed tracks. Files go to `folder` (the project's Audio/).
    public func begin(requests: [RecordRequest], folder: URL, sampleRate: Double, captureStart: Int, captureEnd: Int,
                      takeName: String) throws -> RecordSession {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lanes: [RecordSession.Lane] = []
        writers = []
        for r in requests {
            let base = "\(r.trackName) \(takeName)"
            let dryURL = ProjectFileNames.unique(in: folder, base: base, ext: "wav")
            let wetURL = r.captureWet ? ProjectFileNames.unique(in: folder, base: base + " (wet)", ext: "wav") : nil
            let lane = RecordSession.Lane(trackID: r.trackID, channels: r.channels == 2 ? 2 : 1, inputFirst: r.inputFirst,
                                          captureWet: r.captureWet, sampleRate: sampleRate, dryURL: dryURL, wetURL: wetURL)
            // Float32 files: no clipping/quantisation at record time; convert on export.
            let dw = try StreamingWAVWriter(url: dryURL, sampleRate: sampleRate, channels: lane.channels, format: .float32)
            let ww = try wetURL.map { try StreamingWAVWriter(url: $0, sampleRate: sampleRate, channels: 2, format: .float32) }
            writers.append((lane, dw, ww))
            lanes.append(lane)
        }
        let s = RecordSession(lanes: lanes, captureStart: captureStart, captureEnd: captureEnd, sampleRate: sampleRate)
        session = s
        running.value = true
        let t = Thread { [weak self] in self?.diskLoop() }
        t.name = "Fitzrovia Records DAW Disk Writer"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        return s
    }

    private func diskLoop() {
        var scratch = [Float](repeating: 0, count: 16384)
        while running.value {
            drainAll(&scratch)
            Thread.sleep(forTimeInterval: 0.01)
        }
        drainAll(&scratch)
        finished.signal()
    }

    private func drainAll(_ scratch: inout [Float]) {
        for w in writers {
            drain(w.lane.dry, channels: w.lane.channels, writer: w.dry, scratch: &scratch)
            if let ring = w.lane.wet, let ww = w.wet { drain(ring, channels: 2, writer: ww, scratch: &scratch) }
        }
    }

    private func drain(_ ring: SPSCRingBuffer, channels: Int, writer: StreamingWAVWriter, scratch: inout [Float]) {
        let chunk = (scratch.count / channels) * channels
        while true {
            let avail = (ring.availableToRead / channels) * channels
            if avail <= 0 { return }
            let n = min(avail, chunk)
            scratch.withUnsafeMutableBufferPointer { buf in
                let got = ring.read(into: buf.baseAddress!, count: n)
                do { try writer.append(interleaved: UnsafePointer(buf.baseAddress!), frames: got / channels) }
                catch { lastError = error.localizedDescription }
            }
        }
    }

    /// Stops the disk thread (call after the audio thread stopped capturing) and finalises files.
    public func finish() -> [RecordedTake] {
        guard let s = session else { return [] }
        // Give the audio thread a moment to finish its current block.
        Thread.sleep(forTimeInterval: 0.03)
        running.value = false
        if thread != nil { finished.wait() }
        thread = nil
        var takes: [RecordedTake] = []
        for w in writers {
            do { try w.dry.finish(); try w.wet?.finish() } catch { lastError = error.localizedDescription }
            let frames = w.dry.frameCount
            let first = w.lane.firstFrame.value
            if frames == 0 || first == Int.min {
                try? FileManager.default.removeItem(at: w.lane.dryURL)
                if let u = w.lane.wetURL { try? FileManager.default.removeItem(at: u) }
                continue
            }
            takes.append(RecordedTake(trackID: w.lane.trackID, dryURL: w.lane.dryURL, wetURL: w.lane.wetURL,
                                      startFrame: first, frames: frames, sampleRate: s.sampleRate,
                                      hadOverflow: w.lane.overflow.value))
        }
        writers = []
        session = nil
        return takes
    }
}

public enum ProjectFileNames {
    public static func unique(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = dir.appendingPathComponent(clean).appendingPathExtension(ext)
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(clean) \(i)").appendingPathExtension(ext)
            i += 1
        }
        return url
    }
}
