#!/usr/bin/env python3
"""
Convert Demucs v4 "htdemucs_6s" (6 stems: drums, bass, other, vocals, guitar, piano) to Core ML
for Fitzrovia Records DAW's on-device stem separation.

Run this on a Mac (Apple Silicon recommended), ideally in a fresh virtualenv:

    python3 -m venv ~/sf-demucs && source ~/sf-demucs/bin/activate
    pip install "torch>=2.1,<2.6" "demucs==4.0.1" "coremltools>=7.2" numpy
    python3 tools/convert_demucs_to_coreml.py --out ~/Desktop/htdemucs_6s.mlpackage

The first run downloads the pretrained PyTorch weights (via the demucs package). Then, in
Fitzrovia Records DAW: Separate Stems ▸ Model ▸ Import… and pick the produced .mlpackage (or zip it and host
it yourself, then set Settings ▸ Stem Separation ▸ Model URL to use the in-app downloader).

Why the patching below?
  * coremltools cannot represent complex tensors and has no istft op, so HTDemucs' internal
    STFT/ISTFT are replaced with *real-valued* equivalents (conv1d with a DFT basis for the STFT,
    a matrix inverse DFT + conv_transpose1d overlap-add for the ISTFT). The complex spectrogram is
    carried as a trailing [..., 2] (real, imag) dimension. These match torch.stft/istft with
    hann window, center=True, reflect padding and normalized=True (as used by demucs.spec).
  * PyTorch's fused multi-head-attention fast path is disabled so the transformer traces into
    primitive ops.
  * The model is traced with a fixed segment length (7.8 s @ 44.1 kHz). Fitzrovia Records DAW runs the
    model over overlapping segments with cross-fades.

The script verifies the patched PyTorch model against the original before converting
(`--skip-verify` to skip) and, on macOS, checks the Core ML output against PyTorch.

I/O contract (must match Sources/SFSeparation/CoreMLSeparator.swift, DemucsModelContract):
    input  "mix":     float32 [1, 2, SEGMENT]
    output "sources": float32 [1, 6, 2, SEGMENT]   order: drums, bass, other, vocals, guitar, piano
"""
import argparse
import math
import sys
import types

import numpy as np
import torch
import torch.nn.functional as F

SAMPLE_RATE = 44100
SEGMENT = 343980  # 7.8 s, htdemucs training segment


# --------------------------------------------------------------------------------------------
# Real-valued STFT / ISTFT equivalent to demucs.spec.spectro / ispectro
# --------------------------------------------------------------------------------------------
class RealSTFT(torch.nn.Module):
    """torch.stft(x, n_fft, hop, window=hann(n_fft), normalized=True, center=True, pad_mode='reflect')
    returning [..., freqs, frames, 2] instead of a complex tensor."""

    def __init__(self, n_fft, hop):
        super().__init__()
        self.n_fft, self.hop = n_fft, hop
        win = torch.hann_window(n_fft, periodic=True, dtype=torch.float64)
        n = torch.arange(n_fft, dtype=torch.float64)
        k = torch.arange(n_fft // 2 + 1, dtype=torch.float64)
        ang = 2 * math.pi * k[:, None] * n[None, :] / n_fft
        scale = 1.0 / math.sqrt(n_fft)  # normalized=True
        cos_k = (torch.cos(ang) * win[None, :] * scale).float()
        sin_k = (-torch.sin(ang) * win[None, :] * scale).float()
        self.register_buffer("kernel", torch.cat([cos_k, sin_k], 0)[:, None, :])  # [2F, 1, n_fft]

    def forward(self, x):
        *other, length = x.shape
        x = x.reshape(-1, 1, length)
        p = self.n_fft // 2
        x = F.pad(x, (p, p), mode="reflect")
        y = F.conv1d(x, self.kernel, stride=self.hop)  # [B, 2F, frames]
        freqs = self.n_fft // 2 + 1
        re, im = y[:, :freqs], y[:, freqs:]
        z = torch.stack([re, im], dim=-1)  # [B, F, frames, 2]
        return z.reshape(*other, freqs, z.shape[-2], 2)


class RealISTFT(torch.nn.Module):
    """torch.istft(z, n_fft, hop, window=hann(n_fft), normalized=True, center=True, length=L)
    for z given as [..., freqs, frames, 2]. Built for a fixed number of frames / output length."""

    def __init__(self, n_fft, hop, frames, length):
        super().__init__()
        self.n_fft, self.hop, self.frames, self.length = n_fft, hop, frames, length
        freqs = n_fft // 2 + 1
        win = torch.hann_window(n_fft, periodic=True, dtype=torch.float64)
        n = torch.arange(n_fft, dtype=torch.float64)
        k = torch.arange(freqs, dtype=torch.float64)
        ang = 2 * math.pi * k[:, None] * n[None, :] / n_fft
        # irfft: x[n] = 1/N (X0 + (-1)^n X_{N/2} + 2 sum_{k=1}^{N/2-1} Re(X_k e^{+i ang}))
        w = torch.full((freqs, 1), 2.0, dtype=torch.float64)
        w[0] = 1.0
        w[-1] = 1.0
        scale = math.sqrt(n_fft) / n_fft  # normalized=True undoes 1/sqrt(N); irfft has 1/N
        cos_b = torch.cos(ang) * w * scale * win[None, :]
        sin_b = -torch.sin(ang) * w * scale * win[None, :]
        sin_b[0] = 0
        sin_b[-1] = 0
        # conv_transpose1d weight: [in_channels=2F, out_channels=1, kernel=n_fft]
        self.register_buffer("basis", torch.cat([cos_b, sin_b], 0).float()[:, None, :])
        # Window-square envelope for normalisation (constant because frames/length are fixed).
        total = n_fft + hop * (frames - 1)
        env = torch.zeros(total, dtype=torch.float64)
        for f in range(frames):
            env[f * hop: f * hop + n_fft] += win ** 2
        p = n_fft // 2
        env = env[p: p + length]
        self.register_buffer("inv_env", torch.where(env > 1e-11, 1.0 / env, torch.zeros_like(env)).float())

    def forward(self, z):
        *other, freqs, frames, _ = z.shape
        z = z.reshape(-1, freqs, frames, 2)
        y = torch.cat([z[..., 0], z[..., 1]], dim=1)  # [B, 2F, frames]
        x = F.conv_transpose1d(y, self.basis, stride=self.hop)  # [B, 1, total]
        p = self.n_fft // 2
        x = x[:, 0, p: p + self.length] * self.inv_env
        return x.reshape(*other, self.length)


# --------------------------------------------------------------------------------------------
# Patch HTDemucs to use real spectrograms
# --------------------------------------------------------------------------------------------
def patch_htdemucs(model, segment):
    """Replaces _spec/_magnitude/_mask/_ispec with real-valued versions (CaC mode only)."""
    assert model.cac, "Only complex-as-channels HTDemucs models are supported"
    hl, nfft = model.hop_length, model.nfft
    assert hl == nfft // 4
    le = int(math.ceil(segment / hl))
    stft = RealSTFT(nfft, hl)
    # Mirrors HTDemucs._ispec padding: frames = le + 4 after padding, length = hl*le + 2*pad.
    pad = hl // 2 * 3
    ist_len = hl * le + 2 * pad
    istft = RealISTFT(nfft, hl, le + 4, ist_len)
    model.add_module("_sf_stft", stft)
    model.add_module("_sf_istft", istft)

    def _spec(self, x):
        le_ = int(math.ceil(x.shape[-1] / hl))
        x = F.pad(x, (pad, pad + le_ * hl - x.shape[-1]), mode="reflect")
        z = self._sf_stft(x)[..., :-1, :, :]  # drop Nyquist bin
        return z[..., 2: 2 + le_, :]

    def _magnitude(self, z):
        # z: [B, C, Fr, T, 2] -> [B, C*2, Fr, T]  (same layout as view_as_real().permute(0,1,4,2,3))
        B, C, Fr, T, _ = z.shape
        return z.permute(0, 1, 4, 2, 3).reshape(B, C * 2, Fr, T)

    def _mask(self, z, m):
        # m: [B, S, C*2, Fr, T] -> [B, S, C, Fr, T, 2]
        B, S, C, Fr, T = m.shape
        return m.view(B, S, -1, 2, Fr, T).permute(0, 1, 2, 4, 5, 3)

    def _ispec(self, z, length=None, scale=0):
        assert scale == 0
        z = F.pad(z, (0, 0, 0, 0, 0, 1))  # add Nyquist bin back (zeros)
        z = F.pad(z, (0, 0, 2, 2))        # 2 frames each side
        x = self._sf_istft(z)
        return x[..., pad: pad + length]

    model._spec = types.MethodType(_spec, model)
    model._magnitude = types.MethodType(_magnitude, model)
    model._mask = types.MethodType(_mask, model)
    model._ispec = types.MethodType(_ispec, model)
    return model


class Wrapper(torch.nn.Module):
    def __init__(self, core):
        super().__init__()
        self.core = core

    def forward(self, mix):
        return self.core(mix)


def load_htdemucs():
    from demucs.pretrained import get_model
    bag = get_model("htdemucs_6s")
    m = bag.models[0] if hasattr(bag, "models") else bag
    m.eval()
    return m


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="htdemucs_6s.mlpackage")
    ap.add_argument("--fp16", action="store_true", help="FP16 weights (smaller, slightly less accurate)")
    ap.add_argument("--skip-verify", action="store_true")
    args = ap.parse_args()

    if hasattr(torch.backends, "mha") and hasattr(torch.backends.mha, "set_fastpath_enabled"):
        torch.backends.mha.set_fastpath_enabled(False)

    print("Loading htdemucs_6s (downloads weights on first run)…")
    original = load_htdemucs()
    print("Sources:", original.sources)
    assert list(original.sources) == ["drums", "bass", "other", "vocals", "guitar", "piano"], original.sources

    patched = patch_htdemucs(load_htdemucs(), SEGMENT)
    wrapper = Wrapper(patched).eval()
    torch.manual_seed(0)
    example = torch.randn(1, 2, SEGMENT) * 0.1

    if not args.skip_verify:
        print("Verifying patched STFT/ISTFT against torch.stft/istft…")
        from demucs.spec import spectro, ispectro
        x = torch.randn(2, SEGMENT)
        ref = torch.view_as_real(spectro(x, original.nfft, original.hop_length))
        ours = RealSTFT(original.nfft, original.hop_length)(x)
        print("  STFT max abs diff:", (ref - ours).abs().max().item())
        with torch.no_grad():
            a = original(example)
            b = wrapper(example)
        diff = (a - b).abs().max().item()
        print(f"  Model output max abs diff (patched vs original): {diff:.2e}")
        if diff > 1e-2:
            print("  WARNING: patched model deviates from the original; check your torch/demucs versions.")

    print("Tracing…")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, check_trace=False)

    import coremltools as ct
    print("Converting to Core ML (this can take several minutes and lots of RAM)…")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix", shape=(1, 2, SEGMENT), dtype=np.float32)],
        outputs=[ct.TensorType(name="sources", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "Demucs htdemucs_6s source separation (drums, bass, other, vocals, guitar, piano)"
    mlmodel.author = "Converted for Fitzrovia Records DAW from facebookresearch/demucs (MIT)"
    mlmodel.user_defined_metadata["sampleRate"] = str(SAMPLE_RATE)
    mlmodel.user_defined_metadata["segment"] = str(SEGMENT)
    mlmodel.user_defined_metadata["sources"] = "drums,bass,other,vocals,guitar,piano"
    mlmodel.save(args.out)
    print("Saved", args.out)

    if sys.platform == "darwin" and not args.skip_verify:
        print("Checking Core ML prediction against PyTorch…")
        out = mlmodel.predict({"mix": example.numpy()})["sources"]
        with torch.no_grad():
            ref = wrapper(example).numpy()
        print("  Core ML vs PyTorch max abs diff:", float(np.abs(out - ref).max()))
    print("Done. Import the .mlpackage in Fitzrovia Records DAW ▸ Separate Stems ▸ Model ▸ Import…")


if __name__ == "__main__":
    main()
