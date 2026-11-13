import Foundation

/// Time–frequency helpers for soft masks laid out frames × bins (row-major by frame).
public enum MaskOps {
    /// Separable box blur with radius `rt` frames and `rf` bins (edge-normalised, O(n)).
    public static func boxBlur(_ a: [Float], frames: Int, bins: Int, rt: Int, rf: Int) -> [Float] {
        guard frames > 0, bins > 0, rt > 0 || rf > 0 else { return a }
        var tmp = a
        if rf > 0 {
            for f in 0..<frames {
                let base = f * bins
                var acc: Float = 0
                var lo = 0, hi = -1
                for b in 0..<bins {
                    let nlo = max(0, b - rf), nhi = min(bins - 1, b + rf)
                    while hi < nhi { hi += 1; acc += a[base + hi] }
                    while lo < nlo { acc -= a[base + lo]; lo += 1 }
                    tmp[base + b] = acc / Float(hi - lo + 1)
                }
            }
        }
        guard rt > 0 else { return tmp }
        var out = tmp
        for b in 0..<bins {
            var acc: Float = 0
            var lo = 0, hi = -1
            for f in 0..<frames {
                let nlo = max(0, f - rt), nhi = min(frames - 1, f + rt)
                while hi < nhi { hi += 1; acc += tmp[hi * bins + b] }
                while lo < nlo { acc -= tmp[lo * bins + b]; lo += 1 }
                out[f * bins + b] = acc / Float(hi - lo + 1)
            }
        }
        return out
    }

    /// Normalised positive spectral flux per frame (0…1), used to detect transients.
    public static func transientCurve(_ mag: [Float], frames: Int, bins: Int) -> [Float] {
        var flux = [Float](repeating: 0, count: frames)
        guard frames > 1 else { return flux }
        for f in 1..<frames {
            var s: Float = 0, e: Float = 0
            let a = f * bins, p = (f - 1) * bins
            for b in 0..<bins {
                let d = mag[a + b] - mag[p + b]
                if d > 0 { s += d }
                e += mag[a + b]
            }
            flux[f] = e > 1e-9 ? s / e : 0
        }
        // Adaptive: compare with a local median-ish baseline (moving average) to find peaks.
        let r = 8
        var out = flux
        for f in 0..<frames {
            var acc: Float = 0; var n = 0
            for t in max(0, f - r)...min(frames - 1, f + r) { acc += flux[t]; n += 1 }
            let base = acc / Float(n)
            out[f] = min(1, max(0, (flux[f] - 1.5 * base) / max(1e-6, 1.5 * base + 0.05)))
        }
        return out
    }

    /// Rescales masks so that their sum never exceeds 1 in any bin.
    public static func normalise(_ masks: inout [[Float]]) {
        guard let count = masks.first?.count else { return }
        for i in 0..<count {
            var s: Float = 0
            for m in masks { s += m[i] }
            if s > 1 { let g = 1 / s; for k in masks.indices { masks[k][i] *= g } }
        }
    }
}

/// Reduces typical spectral-masking artefacts: "musical noise" (isolated speckles), warbling,
/// low-level bleed and HF harshness. Works on soft masks before resynthesis.
///  1. Time–frequency smoothing of each mask (radius grows with strength).
///  2. Transient preservation: on onset frames the raw mask is blended back so attacks stay sharp.
///  3. Extra temporal smoothing above ~6 kHz (de-ess / harshness).
///  4. Soft mask floor: weak mask values are pushed towards 0 with a smooth knee.
///  5. Spectral gate: bins far below the stem's own frame level, and frames far below its
///     loudest frame, are attenuated (removes faint residue in "silent" passages).
///  6. Renormalisation so masks never sum above 1.
public struct ArtefactReducer {
    public var strength: Float
    public init(strength: Float) { self.strength = min(1, max(0, strength)) }

    public func refine(_ masks: [[Float]], mixMagnitude mag: [Float], frames: Int, bins: Int,
                       binHz: Float) -> [[Float]] {
        guard strength > 0, frames > 0, bins > 0 else { return masks }
        let s = strength
        let transient = MaskOps.transientCurve(mag, frames: frames, bins: bins)
        let rt = 1 + Int((2 * s).rounded()), rf = 1 + Int(s.rounded())
        let hfBin = min(bins, max(0, Int(6000 / max(binHz, 1e-3))))
        let knee = 0.08 + 0.17 * s                       // soft floor threshold
        let gateDB = 60 - 25 * s                         // bins below (frame peak − gateDB) are gated
        let gateRatio = powf(10, -gateDB / 20)
        let frameGateRatio = powf(10, -(50 - 15 * s) / 20)

        var out: [[Float]] = []
        for raw in masks {
            let blurred = MaskOps.boxBlur(raw, frames: frames, bins: bins, rt: rt, rf: rf)
            let hfBlur = hfBin < bins ? MaskOps.boxBlur(raw, frames: frames, bins: bins, rt: rt + 2, rf: rf) : blurred
            var m = raw
            for f in 0..<frames {
                let keep = transient[f] * (1 - 0.5 * s)
                let base = f * bins
                for b in 0..<bins {
                    let i = base + b
                    let sm = b >= hfBin ? hfBlur[i] : blurred[i]
                    let smoothed = (1 - s) * raw[i] + s * sm
                    var v = min(1, max(0, keep * raw[i] + (1 - keep) * smoothed))
                    if !v.isFinite { v = 0 }
                    // Smooth knee: v * smoothstep(v / knee)
                    if v < knee { let x = v / knee; v *= x * x * (3 - 2 * x) }
                    m[i] = v
                }
            }
            // Spectral gate relative to the stem's own level.
            var frameE = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                let base = f * bins
                var peak: Float = 0, e: Float = 0
                for b in 0..<bins { let v = m[base + b] * mag[base + b]; peak = max(peak, v); e += v * v }
                frameE[f] = e
                let thr = peak * gateRatio
                guard thr > 1e-30, thr.isFinite else { continue }
                for b in 0..<bins {
                    let v = m[base + b] * mag[base + b]
                    if v < thr { let x = v / thr; m[base + b] *= x * x }
                }
            }
            let maxE = frameE.max() ?? 0
            if maxE > 1e-30 && maxE.isFinite {
                let thrE = maxE * frameGateRatio * frameGateRatio
                for f in 0..<frames where frameE[f] < thrE {
                    let g = sqrtf(frameE[f] / thrE)
                    let base = f * bins
                    for b in 0..<bins { m[base + b] *= g }
                }
            }
            out.append(m)
        }
        MaskOps.normalise(&out)
        return out
    }
}
