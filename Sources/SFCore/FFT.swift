import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Complex FFT of power-of-two size. Uses vDSP (Accelerate) on Apple platforms and a portable
/// radix-2 implementation elsewhere (so the same DSP code can be unit-tested on any OS).
/// `forward`/`inverse` are allocation-free and real-time safe once constructed.
public final class FFT {
    public let size: Int
    public let log2n: Int
    private let tmpRe: UnsafeMutablePointer<Float>
    private let tmpIm: UnsafeMutablePointer<Float>
    #if canImport(Accelerate)
    private let setupF: OpaquePointer
    private let setupI: OpaquePointer
    #else
    private let cosT: [Float]
    private let sinT: [Float]
    private let bitrev: [Int]
    #endif

    public init(size: Int) {
        precondition(size >= 16 && size & (size - 1) == 0, "FFT size must be a power of two >= 16")
        self.size = size
        var l = 0
        while (1 << l) < size { l += 1 }
        log2n = l
        tmpRe = .allocate(capacity: size); tmpRe.initialize(repeating: 0, count: size)
        tmpIm = .allocate(capacity: size); tmpIm.initialize(repeating: 0, count: size)
        #if canImport(Accelerate)
        setupF = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        setupI = vDSP_DFT_zop_CreateSetup(setupF, vDSP_Length(size), .INVERSE)!
        #else
        var c = [Float](repeating: 0, count: size / 2), s = c
        for i in 0..<size / 2 {
            let a = -2 * Double.pi * Double(i) / Double(size)
            c[i] = Float(cos(a)); s[i] = Float(sin(a))
        }
        cosT = c; sinT = s
        var br = [Int](repeating: 0, count: size)
        for i in 0..<size {
            var x = i, r = 0
            for _ in 0..<l { r = (r << 1) | (x & 1); x >>= 1 }
            br[i] = r
        }
        bitrev = br
        #endif
    }

    deinit {
        tmpRe.deallocate(); tmpIm.deallocate()
        #if canImport(Accelerate)
        vDSP_DFT_DestroySetup(setupI)
        vDSP_DFT_DestroySetup(setupF)
        #endif
    }

    /// Forward transform (no scaling). Inputs and outputs may alias.
    public func forward(inRe: UnsafePointer<Float>, inIm: UnsafePointer<Float>,
                        outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>) {
        transform(inRe, inIm, outRe, outIm, inverse: false)
    }

    /// Inverse transform, scaled by 1/N so that inverse(forward(x)) == x.
    public func inverse(inRe: UnsafePointer<Float>, inIm: UnsafePointer<Float>,
                        outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>) {
        transform(inRe, inIm, outRe, outIm, inverse: true)
        let s = 1 / Float(size)
        for i in 0..<size { outRe[i] *= s; outIm[i] *= s }
    }

    private func transform(_ inRe: UnsafePointer<Float>, _ inIm: UnsafePointer<Float>,
                           _ outRe: UnsafeMutablePointer<Float>, _ outIm: UnsafeMutablePointer<Float>, inverse: Bool) {
        tmpRe.update(from: inRe, count: size)
        tmpIm.update(from: inIm, count: size)
        #if canImport(Accelerate)
        vDSP_DFT_Execute(inverse ? setupI : setupF, tmpRe, tmpIm, outRe, outIm)
        #else
        for i in 0..<size { let j = bitrev[i]; outRe[j] = tmpRe[i]; outIm[j] = tmpIm[i] }
        let sign: Float = inverse ? -1 : 1
        var len = 2
        while len <= size {
            let half = len / 2
            let step = size / len
            var start = 0
            while start < size {
                for k in 0..<half {
                    let wr = cosT[k * step], wi = sign * sinT[k * step]
                    let a = start + k, b = a + half
                    let tr = outRe[b] * wr - outIm[b] * wi
                    let ti = outRe[b] * wi + outIm[b] * wr
                    outRe[b] = outRe[a] - tr; outIm[b] = outIm[a] - ti
                    outRe[a] += tr; outIm[a] += ti
                }
                start += len
            }
            len <<= 1
        }
        #endif
    }

    /// Convenience (allocating, non-real-time): magnitude spectrum of a real frame (N/2+1 bins).
    public func magnitudes(_ frame: [Float]) -> [Float] {
        var re = [Float](repeating: 0, count: size), im = re
        for i in 0..<min(size, frame.count) { re[i] = frame[i] }
        var oRe = re, oIm = im
        re.withUnsafeBufferPointer { r in im.withUnsafeBufferPointer { i in
            oRe.withUnsafeMutableBufferPointer { or in oIm.withUnsafeMutableBufferPointer { oi in
                forward(inRe: r.baseAddress!, inIm: i.baseAddress!, outRe: or.baseAddress!, outIm: oi.baseAddress!)
            } }
        } }
        im = []
        return (0...size / 2).map { sqrtf(oRe[$0] * oRe[$0] + oIm[$0] * oIm[$0]) }
    }
}

public enum Window {
    public static func hann(_ n: Int) -> [Float] {
        (0..<n).map { 0.5 - 0.5 * cosf(twoPi * Float($0) / Float(n)) }
    }
}

/// Short-time Fourier transform used by analysis and separation (non-real-time).
public struct STFT {
    public let frameSize: Int
    public let hop: Int
    public let window: [Float]
    private let fft: FFT
    public var bins: Int { frameSize / 2 + 1 }

    public init(frameSize: Int = 2048, hop: Int = 512) {
        self.frameSize = frameSize; self.hop = hop
        window = Window.hann(frameSize)
        fft = FFT(size: frameSize)
    }

    public func frameCount(for length: Int) -> Int { max(1, (length + frameSize) / hop + 1) }

    /// Returns (re, im) as flat arrays of frames × bins. Signal is zero-padded by frameSize/2 at the start.
    public func analyze(_ x: [Float]) -> (re: [Float], im: [Float], frames: Int) {
        let frames = frameCount(for: x.count)
        let pad = frameSize / 2
        var outRe = [Float](repeating: 0, count: frames * bins)
        var outIm = outRe
        var bufRe = [Float](repeating: 0, count: frameSize)
        var bufIm = bufRe
        var oRe = bufRe, oIm = bufRe
        for f in 0..<frames {
            let start = f * hop - pad
            for i in 0..<frameSize {
                let idx = start + i
                bufRe[i] = (idx >= 0 && idx < x.count) ? x[idx] * window[i] : 0
                bufIm[i] = 0
            }
            fft.forward(inRe: bufRe, inIm: bufIm, outRe: &oRe, outIm: &oIm)
            let base = f * bins
            for b in 0..<bins { outRe[base + b] = oRe[b]; outIm[base + b] = oIm[b] }
        }
        return (outRe, outIm, frames)
    }

    /// Inverse STFT with weighted overlap-add.
    public func synthesize(re: [Float], im: [Float], frames: Int, length: Int) -> [Float] {
        let pad = frameSize / 2
        var out = [Float](repeating: 0, count: length + frameSize * 2)
        var norm = out
        var bRe = [Float](repeating: 0, count: frameSize), bIm = bRe
        var oRe = bRe, oIm = bRe
        for f in 0..<frames {
            let base = f * bins
            for b in 0..<bins { bRe[b] = re[base + b]; bIm[b] = im[base + b] }
            for b in 1..<(frameSize / 2) { bRe[frameSize - b] = bRe[b]; bIm[frameSize - b] = -bIm[b] }
            fft.inverse(inRe: bRe, inIm: bIm, outRe: &oRe, outIm: &oIm)
            let start = f * hop
            for i in 0..<frameSize where start + i < out.count {
                out[start + i] += oRe[i] * window[i]
                norm[start + i] += window[i] * window[i]
            }
        }
        var y = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let n = norm[i + pad]
            y[i] = n > 1e-6 ? out[i + pad] / n : 0
        }
        return y
    }
}

// MARK: - Zero-latency convolution

/// Uniformly-partitioned FFT convolution with a direct-form "head" so total latency is zero.
/// The first `blockSize` taps are convolved directly; the remainder (the "tail") is convolved
/// in the frequency domain whose inherent one-block latency exactly matches the tail's offset.
/// Construct on a non-real-time thread; `process` is allocation-free.
public final class Convolver {
    public let blockSize: Int
    private let headLen: Int
    private let head: [Float]
    private let history: UnsafeMutablePointer<Float>   // doubled ring for contiguous reads
    private var histPos = 0
    // Tail
    private let partitions: Int
    private let fft: FFT
    private let fftSize: Int
    private let hRe: [[Float]], hIm: [[Float]]
    private var xRe: [UnsafeMutablePointer<Float>], xIm: [UnsafeMutablePointer<Float>]
    private var fdlPos = 0
    private let inBlock: UnsafeMutablePointer<Float>
    private let accRe: UnsafeMutablePointer<Float>, accIm: UnsafeMutablePointer<Float>
    private let wRe: UnsafeMutablePointer<Float>, wIm: UnsafeMutablePointer<Float>
    private let tailOut: UnsafeMutablePointer<Float>   // output for the current block
    private let overlap: UnsafeMutablePointer<Float>
    private var blockFill = 0

    public init(ir: [Float], blockSize: Int = 128) {
        self.blockSize = blockSize
        headLen = min(ir.count, blockSize)
        head = Array(ir.prefix(headLen))
        history = .allocate(capacity: blockSize * 2)
        history.initialize(repeating: 0, count: blockSize * 2)
        let tail = ir.count > blockSize ? Array(ir[blockSize...]) : []
        partitions = (tail.count + blockSize - 1) / blockSize
        fftSize = blockSize * 2
        fft = FFT(size: fftSize)
        var hr: [[Float]] = [], hi: [[Float]] = []
        let zeros = [Float](repeating: 0, count: fftSize)
        for p in 0..<partitions {
            var re = zeros
            for i in 0..<blockSize where p * blockSize + i < tail.count { re[i] = tail[p * blockSize + i] }
            var oRe = zeros, oIm = zeros
            fft.forward(inRe: re, inIm: zeros, outRe: &oRe, outIm: &oIm)
            hr.append(oRe); hi.append(oIm)
        }
        hRe = hr; hIm = hi
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: blockSize * 2)
            p.initialize(repeating: 0, count: blockSize * 2); return p
        }
        xRe = (0..<max(1, partitions)).map { _ in alloc() }
        xIm = (0..<max(1, partitions)).map { _ in alloc() }
        inBlock = alloc(); accRe = alloc(); accIm = alloc(); wRe = alloc(); wIm = alloc()
        tailOut = alloc(); overlap = alloc()
    }

    deinit {
        history.deallocate()
        for p in xRe { p.deallocate() }
        for p in xIm { p.deallocate() }
        [inBlock, accRe, accIm, wRe, wIm, tailOut, overlap].forEach { $0.deallocate() }
    }

    public func reset() {
        history.update(repeating: 0, count: blockSize * 2)
        for p in xRe { p.update(repeating: 0, count: fftSize) }
        for p in xIm { p.update(repeating: 0, count: fftSize) }
        tailOut.update(repeating: 0, count: fftSize)
        overlap.update(repeating: 0, count: fftSize)
        blockFill = 0; histPos = 0
    }

    /// Processes `count` samples from `input` to `output` (may alias).
    public func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, count: Int) {
        for n in 0..<count {
            let x = input[n]
            // Direct head
            history[histPos] = x
            history[histPos + blockSize] = x
            var acc: Float = 0
            // history[histPos + blockSize - k] is x[n-k]
            let base = histPos + blockSize
            for k in 0..<headLen { acc += head[k] * history[base - k] }
            histPos = (histPos + 1) % blockSize
            // Tail
            if partitions > 0 {
                acc += tailOut[blockFill]
                inBlock[blockFill] = x
                blockFill += 1
                if blockFill == blockSize { processTailBlock(); blockFill = 0 }
            }
            output[n] = acc
        }
    }

    private func processTailBlock() {
        // Forward FFT of the new input block (zero padded) into the frequency-domain delay line.
        fdlPos = (fdlPos + partitions - 1) % partitions
        for i in blockSize..<fftSize { inBlock[i] = 0 }
        wIm.update(repeating: 0, count: fftSize)
        fft.forward(inRe: inBlock, inIm: wIm, outRe: xRe[fdlPos], outIm: xIm[fdlPos])
        accRe.update(repeating: 0, count: fftSize)
        accIm.update(repeating: 0, count: fftSize)
        for p in 0..<partitions {
            let xr = xRe[(fdlPos + p) % partitions], xi = xIm[(fdlPos + p) % partitions]
            let hr = hRe[p], hi = hIm[p]
            for k in 0..<fftSize {
                accRe[k] += xr[k] * hr[k] - xi[k] * hi[k]
                accIm[k] += xr[k] * hi[k] + xi[k] * hr[k]
            }
        }
        fft.inverse(inRe: accRe, inIm: accIm, outRe: wRe, outIm: wIm)
        for i in 0..<blockSize {
            tailOut[i] = wRe[i] + overlap[i]
            overlap[i] = wRe[i + blockSize]
        }
    }
}
