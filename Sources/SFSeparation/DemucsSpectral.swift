import Foundation
import SFCore

/// The spectrogram front/back end of Demucs v4 (HTDemucs `_spec` / `_ispec`), computed in Swift so
/// the Core ML model only contains the network (complex ops and a rank-6 reshape in the original
/// model cannot be converted). Matches PyTorch: periodic Hann, n_fft 4096, hop 1024, normalized,
/// centre + reflect padding, Nyquist bin dropped, frames cropped to ceil(L / hop).
/// Layout of spectra: [bin][frame] (row-major by bin), 2048 bins × ceil(L / 1024) frames.
public struct DemucsSpectral {
    public let nfft = 4096
    public let hop = 1024
    public var bins: Int { nfft / 2 }
    private let window: [Float]
    private let fft: FFT
    private let scale: Float

    public init() {
        window = Window.hann(4096)
        fft = FFT(size: 4096)
        scale = 1 / sqrtf(4096)
    }

    public func frames(for length: Int) -> Int { (length + hop - 1) / hop }

    /// Reflect-padded sample: torch `F.pad(mode: "reflect")` of x by `pad` on the left.
    @inline(__always) private func sample(_ x: UnsafeBufferPointer<Float>, _ j: Int, pad: Int) -> Float {
        let n = x.count
        guard n > 1 else { return n == 1 ? x[0] : 0 }
        var k = j - pad
        // Repeated reflection keeps very short inputs well defined (torch requires pad < n).
        let period = 2 * (n - 1)
        k = ((k % period) + period) % period
        if k >= n { k = period - k }
        return x[k]
    }

    /// Spectrum of one channel: (re, im), each bins × frames.
    public func forward(_ x: [Float]) -> (re: [Float], im: [Float], frames: Int) {
        let t = frames(for: x.count)
        let pad = hop / 2 * 3
        var re = [Float](repeating: 0, count: bins * t), im = re
        var bRe = [Float](repeating: 0, count: nfft), bIm = bRe, oRe = bRe, oIm = bRe
        x.withUnsafeBufferPointer { xs in
            for f in 0..<t {
                // Frame f of the cropped STFT starts at f·hop in the reflect-padded signal.
                let start = f * hop
                for i in 0..<nfft { bRe[i] = sample(xs, start + i, pad: pad) * window[i]; bIm[i] = 0 }
                fft.forward(inRe: bRe, inIm: bIm, outRe: &oRe, outIm: &oIm)
                for b in 0..<bins { re[b * t + f] = oRe[b] * scale; im[b * t + f] = oIm[b] * scale }
            }
        }
        return (re, im, t)
    }

    /// Inverse of `forward` for a signal of `length` samples (spectra bins × frames, frames = frames(for: length)).
    /// `re`/`im` are read through `index(bin, frame)` so model outputs can be used without copying.
    public func inverse(length: Int, frames t: Int, re: (Int, Int) -> Float, im: (Int, Int) -> Float) -> [Float] {
        let pad = hop / 2 * 3
        // Output covers padded positions [pad, pad + length); frame f covers [f·hop, f·hop + nfft).
        var acc = [Float](repeating: 0, count: length)
        var bRe = [Float](repeating: 0, count: nfft), bIm = bRe, oRe = bRe, oIm = bRe
        let s = sqrtf(Float(nfft))
        for f in 0..<t {
            let start = f * hop - pad
            if start + nfft <= 0 || start >= length { continue }
            for b in 0..<bins { bRe[b] = re(b, f); bIm[b] = im(b, f) }
            bIm[0] = 0
            bRe[bins] = 0; bIm[bins] = 0          // dropped Nyquist bin is zero
            for b in 1..<bins { bRe[nfft - b] = bRe[b]; bIm[nfft - b] = -bIm[b] }
            fft.inverse(inRe: bRe, inIm: bIm, outRe: &oRe, outIm: &oIm)
            let i0 = max(0, -start), i1 = min(nfft, length - start)
            if i0 < i1 { for i in i0..<i1 { acc[start + i] += oRe[i] * s * window[i] } }
        }
        // Window-square envelope over every frame torch's istft sums (2 zero frames each side included).
        var out = acc
        for n in 0..<length {
            let p = n + pad + 2 * hop                 // position in the istft buffer (frames u = f + 2)
            var env: Float = 0
            let uHi = min(t + 3, p / hop), uLo = p >= nfft ? (p - nfft) / hop + 1 : 0
            if uLo <= uHi { for u in uLo...uHi { let w = window[p - u * hop]; env += w * w } }
            out[n] = env > 1e-11 ? acc[n] / env : 0
        }
        return out
    }

    /// Convenience inverse from flat bins × frames arrays.
    public func inverse(re: [Float], im: [Float], frames t: Int, length: Int) -> [Float] {
        inverse(length: length, frames: t, re: { re[$0 * t + $1] }, im: { im[$0 * t + $1] })
    }
}
