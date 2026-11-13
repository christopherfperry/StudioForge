#!/usr/bin/env python3
"""Convert Demucs v4 (htdemucs / htdemucs_6s) to Core ML with the STFT/iSTFT moved OUT of the model.

Why: the full model contains complex-number ops and a rank-6 reshape in `_mask`, which Core ML
cannot represent (earlier conversion attempts failed). The app computes the spectrogram itself
(Swift, `DemucsSpectral`) exactly the way `HTDemucs._spec` does, feeds it in, and does the inverse
STFT of the frequency branch + adds the time branch.

Model I/O (segment = training segment, 343980 samples @ 44.1 kHz, T = ceil(segment/1024) = 336):
  inputs : mix  [1, 2, segment]          stereo waveform
           spec [1, 4, 2048, T]          CaC spectrogram: (L.re, L.im, R.re, R.im), normalized STFT
  outputs: spec_out [1, S*4, 2048, T]    per-source CaC spectrogram (denormalized)
           wave_out [1, S*2, segment]    per-source time-branch waveform (denormalized)
  final source s, channel c = wave_out[2s+c] + iSTFT(spec_out[4s+2c] + i*spec_out[4s+2c+1])

Usage: python convert_htdemucs_core.py --model htdemucs_6s --out htdemucs_6s.mlpackage [--fp16] [--verify]
Requires: torch==2.4, coremltools>=8.1, demucs==4.x
"""
import argparse, math, sys
import numpy as np
import torch
from demucs.pretrained import get_model
from demucs.spec import spectro, ispectro


class Core(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, mix, spec):
        m = self.m
        x = spec
        B, C, Fq, T = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = torch.sqrt(((x - mean) ** 2).sum(dim=(1, 2, 3), keepdim=True) / (C * Fq * T - 1))
        x = (x - mean) / (1e-5 + std)
        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = torch.sqrt(((xt - meant) ** 2).sum(dim=(1, 2), keepdim=True) / (xt.shape[1] * xt.shape[2] - 1))
        xt = (xt - meant) / (1e-5 + stdt)
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_upsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_downsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)
        spec_out = x * std + mean
        wave_out = xt * stdt + meant
        return spec_out, wave_out


def make_spec(m, mix):
    """Exactly HTDemucs._spec + _magnitude (cac)."""
    z = m._spec(mix)
    return m._magnitude(z)


def reference_from_core(m, mix, spec_out, wave_out):
    """What the app does after the model: iSTFT + add."""
    B = mix.shape[0]
    S = len(m.sources)
    L = mix.shape[-1]
    x = spec_out.view(B, S, -1, 2, spec_out.shape[-2], spec_out.shape[-1]).permute(0, 1, 2, 4, 5, 3)
    z = torch.view_as_complex(x.contiguous())
    xs = m._ispec(z, L)
    return wave_out.view(B, S, -1, L) + xs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="htdemucs_6s")
    ap.add_argument("--out", default=None)
    ap.add_argument("--fp16", action="store_true")
    ap.add_argument("--verify", action="store_true", help="only check the split model against the full model")
    ap.add_argument("--dump", default=None, help="write a .npz test vector (mix, spec, outputs) for the Swift tests")
    a = ap.parse_args()

    bag = get_model(a.model)
    m = bag.models[0] if hasattr(bag, "models") else bag
    m.eval()
    seg = int(m.segment * m.samplerate)
    print("sources", m.sources, "segment", seg, "samplerate", m.samplerate, file=sys.stderr)
    torch.manual_seed(0)
    t = torch.arange(seg) / m.samplerate
    mix = (0.3 * torch.sin(2 * math.pi * 110 * t) + 0.1 * torch.randn(seg)).repeat(2, 1)[None] * 0.5
    mix[:, 1] *= 0.8
    core = Core(m).eval()
    with torch.no_grad():
        spec = make_spec(m, mix)
        so, wo = core(mix, spec)
        full = m(mix)
        rec = reference_from_core(m, mix, so, wo)
    err = (full - rec).abs().max().item()
    print(f"split-vs-full max abs error: {err:.3e} (full peak {full.abs().max().item():.3f})", file=sys.stderr)
    if a.dump:
        np.savez_compressed(a.dump, mix=mix.numpy(), spec=spec.numpy(), spec_out=so.numpy(), wave_out=wo.numpy(),
                            full=full.numpy())
    if a.verify:
        return
    import coremltools as ct
    # nn.MultiheadAttention's eval fast path emits _native_multi_head_attention (no Core ML op).
    torch.backends.mha.set_fastpath_enabled(False)
    with torch.no_grad():
        traced = torch.jit.trace(core, (mix, spec), check_trace=False)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix", shape=mix.shape, dtype=np.float32),
                ct.TensorType(name="spec", shape=spec.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="spec_out", dtype=np.float32), ct.TensorType(name="wave_out", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16 if a.fp16 else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS13,
    )
    ml.short_description = f"Demucs v4 {a.model} core (STFT outside). Sources: {','.join(m.sources)}"
    ml.user_defined_metadata["sources"] = ",".join(m.sources)
    ml.user_defined_metadata["segment"] = str(seg)
    ml.user_defined_metadata["samplerate"] = str(m.samplerate)
    ml.user_defined_metadata["license"] = "MIT (Demucs, Meta Platforms)"
    ml.save(a.out or f"{a.model}.mlpackage")
    print("saved", a.out or f"{a.model}.mlpackage", file=sys.stderr)


if __name__ == "__main__":
    main()
