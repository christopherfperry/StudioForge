#!/usr/bin/env python3
"""
Generates StudioForge's factory preset library (one JSON file per preset) into
Sources/SFPresets/Resources/Presets.

All presets are ORIGINAL settings for StudioForge's own DSP. Artist names describe the general
tonal territory ("in the style of"); nothing is copied from any recording or proprietary plugin.

You never need to run this to use the app: the generated JSON files are committed. Edit this
script (or the JSON directly, or save presets from the app) to change or add sounds.

Usage:  python3 tools/generate_presets.py
"""
import json
import os
import re
import shutil

OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "SFPresets", "Resources", "Presets")

# ----------------------------------------------------------------------------------------------
# Effect building blocks. Parameter ids must match the ParameterSpec ids in Sources/SFEffects.
# (The unit test `PresetTests.testFactoryPresetsReferenceValidParameters` enforces this.)
# ----------------------------------------------------------------------------------------------

def fx(type_, mix=1.0, bypassed=False, extra=None, **params):
    d = {"type": type_, "mix": mix, "bypassed": bypassed, "params": {k: float(v) for k, v in params.items()}}
    if extra:
        d["extra"] = extra
    return d

def gate(th=-55, rel=80, rng=-80, hold=20): return fx("gate", threshold=th, release=rel, range=rng, hold=hold)
def comp(th=-18, ratio=4, att=10, rel=120, makeup=4, knee=6, sc=20):
    return fx("compressor", threshold=th, ratio=ratio, attack=att, release=rel, makeup=makeup, knee=knee, sidechainHPF=sc)
def limiter(ceil=-0.5, inp=0, rel=60): return fx("limiter", ceiling=ceil, input=inp, release=rel)
def eq(**kw): return fx("eq", **kw)
def dist(mode, drive, tone=5000, hpf=80, out=-8, bias=0):
    modes = ["Overdrive", "Distortion", "Fuzz", "Tube", "Hard Clip", "Foldback", "Rectifier", "Tape"]
    return fx("distortion", mode=modes.index(mode), drive=drive, tone=tone, preHPF=hpf, output=out, bias=bias)
def amp(model, gain, bass=5, mid=5, treble=6, presence=5, master=-14, sag=0.3, tight=90):
    models = ["Clean", "Crunch", "British Lead", "US High Gain", "Modern Metal", "Bass Amp", "Goth Clean", "Fuzz Stack"]
    return fx("amp", model=models.index(model), gain=gain, bass=bass, mid=mid, treble=treble, presence=presence,
              master=master, sag=sag, tight=tight)
def cab(model, mic=0.3, low=70, high=11000, out=0):
    models = ["1x12 Open Back", "2x12 Vintage", "4x12 Closed (V-type)", "4x12 Greenback", "4x10 Bass",
              "8x10 Bass", "1x8 Lo-Fi", "Megaphone", "Custom IR"]
    return fx("cabinet", model=models.index(model), mic=mic, lowCut=low, highCut=high, output=out)
def chorus(rate=0.8, depth=4, delay=12, voices=2, fb=0.1, spread=0.8, wet=0.5):
    return fx("chorus", rate=rate, depth=depth, delay=delay, voices=voices, feedback=fb, spread=spread, wet=wet)
def flanger(rate=0.25, depth=0.7, delay=2, fb=0.6, wet=0.5): return fx("flanger", rate=rate, depth=depth, delay=delay, feedback=fb, wet=wet)
def phaser(rate=0.4, depth=0.8, center=800, stages=6, fb=0.5, wet=0.5):
    return fx("phaser", rate=rate, depth=depth, center=center, stages=stages, feedback=fb, wet=wet)
def tremolo(rate=5, depth=0.6, shape=0, stereo=0): return fx("tremolo", rate=rate, depth=depth, shape=shape, stereo=stereo)
def delay(time=380, sync=0, fb=0.35, wet=0.3, pp=0, low=120, high=6000, mod=0.1, drive=0, off=0):
    syncs = {"off": 0, "1/2": 1, "1/4": 2, "1/4d": 3, "1/8": 4, "1/8d": 5, "1/8t": 6, "1/16": 7}
    return fx("delay", time=time, sync=syncs.get(sync, sync) if isinstance(sync, str) else sync, feedback=fb, wet=wet,
              pingpong=pp, lowCut=low, highCut=high, modDepth=mod, drive=drive, offsetR=off)
def doubler(dl=18, dr=27, detune=8, width=0.9, wet=0.6): return fx("doubler", delayL=dl, delayR=dr, detune=detune, width=width, wet=wet)
def pitch(semi=-12, cents=0, window=50, wet=0.5, detR=0): return fx("pitchshift", semitones=semi, cents=cents, window=window, wet=wet, detuneR=detR)
def octaver(dry=1, sub1=0.6, sub2=0, up=0, tone=900): return fx("octaver", dry=dry, sub1=sub1, sub2=sub2, up=up, tone=tone)
def filt(mode=0, cutoff=2000, res=0.9, drive=0, lfoRate=0.5, lfoDepth=0):
    return fx("filter", mode=mode, cutoff=cutoff, resonance=res, drive=drive, lfoRate=lfoRate, lfoDepth=lfoDepth)
def formant(vowel=0, shift=0, q=10, lfoRate=0, lfoDepth=0, mix=1.0):
    return fx("formant", mix=mix, vowel=vowel, shift=shift, q=q, lfoRate=lfoRate, lfoDepth=lfoDepth)
def autowah(mode=0, sens=0.6, lo=350, hi=2400, q=5, rate=1.5, rel=120):
    return fx("autowah", mode=mode, sensitivity=sens, minFreq=lo, maxFreq=hi, q=q, rate=rate, release=rel)
def bitcrush(bits=8, ds=4, out=0, mix=1.0): return fx("bitcrusher", mix=mix, bits=bits, downsample=ds, output=out)
def shaper(curve=2, amount=0.5, out=-3, mix=1.0): return fx("waveshaper", mix=mix, curve=curve, amount=amount, output=out)
def ringmod(freq=220, lfoRate=0.2, lfoDepth=0, wet=0.5): return fx("ringmod", frequency=freq, lfoRate=lfoRate, lfoDepth=lfoDepth, wet=wet)
def utility(gain=0, width=1, mono=0): return fx("utility", gain=gain, width=width, mono=mono)

def verb(kind, size=None, decay=None, pre=None, damp=None, low=None, diff=None, mod=None, width=None, wet=0.25, dry=1, **extra):
    p = {"wet": wet, "dry": dry}
    for k, v in (("size", size), ("decay", decay), ("predelay", pre), ("damping", damp), ("lowCut", low),
                 ("diffusion", diff), ("modulation", mod), ("width", width)):
        if v is not None:
            p[k] = v
    p.update(extra)
    return fx("reverb." + kind, **p)
def spring(decay=2, tension=0.5, tone=3500, drip=0.5, wet=0.35): return fx("reverb.spring", decay=decay, tension=tension, tone=tone, drip=drip, wet=wet)
def conv(ir=0, decay=2.5, pre=10, wet=0.3, dry=1): return fx("reverb.convolution", irType=ir, decay=decay, predelay=pre, wet=wet, dry=dry)

# ----------------------------------------------------------------------------------------------
# Instrument building blocks
# ----------------------------------------------------------------------------------------------

def synth(type_="synth.subtractive", **params): return {"type": type_, "params": {k: float(v) for k, v in params.items()}}
def keys(model, **params):
    models = ["Piano", "Electric Piano", "Rhodes", "Organ", "Harpsichord", "String Machine"]
    p = {"model": models.index(model)}; p.update(params)
    return {"type": "keys", "params": {k: float(v) for k, v in p.items()}}
def brass(**params): return {"type": "brass.trumpet", "params": {k: float(v) for k, v in params.items()}}
PAD = {"kick": 36, "rim": 37, "snare": 38, "clap": 39, "tomLow": 41, "hatClosed": 42, "hatPedal": 44, "tomMid": 45,
       "hatOpen": 46, "tomHigh": 48, "crash": 49, "ride": 51, "china": 52, "tambourine": 54, "cowbell": 56, "metal": 75}
def kit(master=-3, **pads):
    """pads: kick={"tune":-3,"decay":0.8,...}"""
    params = {"master": float(master)}
    for name, settings in pads.items():
        for k, v in settings.items():
            params[f"pad{PAD[name]}.{k}"] = float(v)
    return {"type": "drums", "params": params}

# ----------------------------------------------------------------------------------------------

PRESETS = []

def add(name, category, artist, desc, effects, instrument=None, tags=(), beat=None, tempo=None, pid=None):
    PRESETS.append({
        "id": pid or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-"),
        "name": name, "category": category, "artistStyle": artist, "tags": list(tags),
        "description": desc + " Original StudioForge DSP approximation of the general tonal character; not a copy of any recording or plugin.",
        "effects": effects, **({"instrument": instrument} if instrument else {}),
        **({"beatStyle": beat} if beat else {}), **({"tempo": tempo} if tempo else {}),
    })

# ============================== REQUIRED NAMED PRESETS ==============================

add("Tyrant's Serenade Lead", "Guitar", "Paradise Lost",
    "Melodic gothic-doom lead: tight high-gain British stack, gentle chorus for width, dotted-eighth delay and a long dark hall.",
    [gate(-58, 60), dist("Overdrive", 10, 3800, 700, -10), amp("British Lead", 7.2, bass=4.5, mid=6.5, treble=6, presence=5.5, tight=140),
     cab("4x12 Greenback", 0.35, 90, 7500), eq(peak2Freq=800, peak2Gain=2, peak2Q=0.8, peak3Freq=3200, peak3Gain=-1.5, lowCut=100),
     chorus(0.45, 2.5, 14, 2, 0.05, 0.9, 0.3), delay(450, "1/8d", 0.32, 0.22, 1, 250, 4200, 0.15),
     verb("hall", size=0.85, decay=3.8, pre=35, damp=5200, low=180, wet=0.24)],
    tags=["lead", "gothic", "doom", "melodic", "Tyrant's Serenade"], tempo=88)

add("Killing Joke Brass - Post-Punk Stab", "Synth", "Killing Joke",
    "Abrasive post-punk trumpet stabs: bright open bell, growl, slap delay and a gritty amp push.",
    [comp(-20, 4, 5, 90, 5), dist("Tube", 12, 6000, 200, -10), delay(110, "off", 0.15, 0.18), verb("room", size=0.5, decay=0.9, wet=0.18)],
    instrument=brass(brightness=0.85, breath=0.3, vibratoDepth=8, scoop=120, attack=0.02, growl=0.35, ensemble=2, formant=1500, gain=-6),
    tags=["trumpet", "brass", "post-punk"])
add("Killing Joke Brass - Tribal Fanfare", "Synth", "Killing Joke",
    "Massed 3-player trumpet fanfare with cathedral-like space, for the tribal, apocalyptic choruses.",
    [eq(lowCut=150, peak3Freq=2500, peak3Gain=2), comp(-18, 3, 15, 150, 3), verb("cathedral", decay=4.5, wet=0.3)],
    instrument=brass(brightness=0.7, breath=0.2, vibratoRate=5.5, vibratoDepth=20, scoop=60, ensemble=3, growl=0.15, gain=-8),
    tags=["trumpet", "brass", "fanfare"])
add("Killing Joke Brass - Muted Menace", "Synth", "Killing Joke",
    "Harmon-muted trumpet through a dark tape delay: eerie and cold.",
    [delay(380, "1/4", 0.45, 0.3, 1, 300, 2500, 0.3, 0.4), verb("plate", decay=2.2, wet=0.22)],
    instrument=brass(brightness=0.5, breath=0.45, mute=1, vibratoDepth=12, scoop=40, growl=0.0, gain=-4),
    tags=["trumpet", "brass", "muted"])

NIN = "Nine Inch Nails"
# NIN-style synths
add("Reptile - Grinding Synth Bass", "Synth", NIN, "Detuned, filter-swept, distorted mono synth with industrial grit (Reptile-style).",
    [dist("Rectifier", 18, 4000, 60, -12), bitcrush(10, 2, 0, 0.35), comp(-20, 6, 3, 80, 6), verb("room", size=0.4, decay=0.7, wet=0.12)],
    instrument=synth("synth.bass", osc1Wave=0, osc2Wave=1, osc2Detune=12, unison=3, unisonDetune=20, cutoff=500, resonance=3,
                     filterEnv=0.6, filtD=0.25, filtS=0.15, drive=0.6, mono=1, glide=40, lfoRate=0.15, lfoCutoff=0.8),
    tags=["industrial", "Reptile"], beat="nin-reptile", tempo=100)
add("Closer - Funk Synth Bass", "Synth", NIN, "Round, slightly squelchy mono bass synth for an industrial-funk groove (Closer-style).",
    [comp(-18, 4, 8, 100, 4), dist("Tape", 8, 3000, 30, -6), eq(lowShelfFreq=90, lowShelfGain=3, peak2Freq=900, peak2Gain=2)],
    instrument=synth("synth.bass", osc1Wave=1, pulseWidth=0.35, osc2Level=0.3, subLevel=0.7, cutoff=380, resonance=2.5, filterEnv=0.7,
                     filtD=0.18, filtS=0.1, ampR=0.05, mono=1, glide=15),
    tags=["industrial", "Closer", "funk"], beat="nin-closer", tempo=92)
add("Closer - Lead Synth Whine", "Synth", NIN, "Thin, portamento sine/square lead with vibrato that cuts through the mix.",
    [delay(320, "1/8d", 0.3, 0.2), verb("plate", decay=1.8, wet=0.18)],
    instrument=synth(osc1Wave=3, osc2Wave=1, osc2Level=0.25, osc2Octave=1, cutoff=4500, glide=120, mono=1, lfoRate=5.5, lfoPitch=0.15),
    tags=["industrial", "Closer", "lead"], tempo=92)
add("Eraser - Swelling Pad to Noise", "Synth", NIN, "Slow-building detuned pad with noise and a band-pass sweep that erupts into distortion (Eraser-style).",
    [filt(2, 1200, 2.5, 6, 0.05, 2.5), dist("Fuzz", 14, 5000, 100, -14), verb("ambient", decay=8, wet=0.35)],
    instrument=synth(osc1Wave=0, osc2Wave=0, unison=5, unisonDetune=30, noiseLevel=0.25, cutoff=1800, ampA=2.5, ampR=3, filtA=3, filterEnv=0.4),
    tags=["industrial", "Eraser", "pad"], beat="nin-eraser", tempo=84)
add("Happiness in Slavery - Machine Synth", "Synth", NIN, "Mechanical, ring-modulated metallic sequence synth (Happiness in Slavery-style).",
    [ringmod(330, 0.3, 0.5, 0.45), bitcrush(8, 6, 0, 0.4), gate(-40, 30), delay(160, "1/16", 0.25, 0.2)],
    instrument=synth(osc1Wave=1, osc2Wave=0, osc2Semi=7, fmAmount=1.8, cutoff=2600, resonance=4, filterEnv=0.5, filtD=0.08, filtS=0, ampD=0.12, ampS=0.1, mono=1),
    tags=["industrial", "Happiness in Slavery", "mechanical"], beat="nin-happiness-in-slavery", tempo=120)
add("March of the Pigs - Noise Stab", "Synth", NIN, "Short, nasty fuzz-saturated synth stabs for frantic 7/8 stomps (March of the Pigs-style).",
    [dist("Fuzz", 30, 6500, 150, -16), bitcrush(6, 3, 0, 0.3), gate(-36, 25)],
    instrument=synth(osc1Wave=0, osc2Wave=1, osc2Semi=-5, noiseLevel=0.3, cutoff=5000, ampD=0.1, ampS=0, ampR=0.05),
    tags=["industrial", "March of the Pigs"], beat="nin-march-of-the-pigs", tempo=134)
add("Pinion - Rising Drone", "Synth", NIN, "Ominous, slowly-opening drone that rises in pitch and grit (Pinion-style intro).",
    [filt(0, 400, 1.5, 6, 0.03, 3), dist("Tape", 10, 3000, 40, -8), verb("cathedral", decay=6, wet=0.3)],
    instrument=synth(osc1Wave=0, osc2Wave=0, osc2Octave=-1, unison=4, unisonDetune=18, cutoff=600, ampA=3, ampR=4, lfoRate=0.08, lfoCutoff=1.5),
    tags=["industrial", "Pinion", "drone"], beat="nin-pinion", tempo=72)
add("Head Like a Hole - Driving Synth Bass", "Synth", NIN, "Punchy 16th-note sequenced synth bass with bite (Head Like a Hole-style).",
    [comp(-20, 5, 4, 80, 5), dist("Distortion", 10, 4500, 40, -10), eq(peak3Freq=2000, peak3Gain=3)],
    instrument=synth("synth.bass", osc1Wave=0, osc2Wave=1, osc2Detune=8, cutoff=900, resonance=2, filterEnv=0.5, filtD=0.12, filtS=0.2, ampR=0.04, mono=1),
    tags=["industrial", "Head Like a Hole"], beat="nin-head-like-a-hole", tempo=118)
add("Starfuckers, Inc. - Distorted Glam Synth", "Synth", NIN, "Bright, overdriven glam-industrial lead/bass hybrid with bitcrushed edge (Starfuckers, Inc.-style).",
    [dist("Hard Clip", 20, 7000, 80, -14), bitcrush(9, 2, 0, 0.3), comp(-18, 6, 2, 60, 5), delay(200, "1/8", 0.2, 0.15)],
    instrument=synth(osc1Wave=1, osc2Wave=0, osc2Octave=-1, fmAmount=0.8, unison=2, unisonDetune=12, cutoff=3200, resonance=2, filterEnv=0.5, filtD=0.2, mono=1),
    tags=["industrial", "Starfuckers"], beat="nin-starfuckers", tempo=128)

# NIN beat/kit presets (Drums category): kit + beat style
def nin_kit(name, beat, tempo, desc, kitdef, fxchain):
    add(name, "Drums", NIN, desc, fxchain, instrument=kitdef, tags=["industrial", "kit", "beat"], beat=beat, tempo=tempo)

nin_kit("Closer Kit - Dry Heavy Kick", "nin-closer", 92, "Huge dry, compressed kick, tight snappy snare, crunchy hats; industrial-funk groove at ~92 BPM.",
        kit(-2, kick={"tune": -4, "decay": 1.4, "tone": 0.35, "snap": 0.8, "drive": 0.45, "level": 2},
            snare={"tune": 1, "decay": 0.6, "tone": 0.6, "snap": 0.7, "drive": 0.2},
            hatClosed={"decay": 0.5, "tone": 0.7, "drive": 0.3}, hatOpen={"decay": 1.6}),
        [comp(-22, 6, 15, 120, 6), dist("Tape", 6, 9000, 20, -4), eq(lowShelfFreq=70, lowShelfGain=4, peak2Freq=400, peak2Gain=-3), limiter(-0.8, 2)])
nin_kit("Reptile Kit - Crushed Machine", "nin-reptile", 100, "Grinding, bitcrushed drum machine with metallic hits.",
        kit(-3, kick={"tune": -2, "decay": 1.1, "drive": 0.6}, snare={"tune": 2, "snap": 0.9, "drive": 0.5}, metal={"level": -2, "decay": 1.2}),
        [bitcrush(10, 3, 0, 0.5), comp(-20, 8, 3, 80, 6), verb("gated", wet=0.15)])
nin_kit("Eraser Kit - Building Tribal", "nin-eraser", 84, "Toms-heavy tribal build with distortion bloom.",
        kit(-3, tomLow={"tune": -7, "decay": 1.6, "drive": 0.3}, tomMid={"tune": -2, "decay": 1.3}, kick={"decay": 1.2, "drive": 0.3}),
        [dist("Tape", 10, 6000, 30, -8), comp(-18, 4, 20, 150, 4), verb("hall", decay=2.5, wet=0.18)])
nin_kit("Happiness in Slavery Kit - Mechanical", "nin-happiness-in-slavery", 120, "Clanking, mechanical, quantized kit with metal percussion and gated room.",
        kit(-3, kick={"tune": 0, "decay": 0.8, "snap": 0.9, "drive": 0.5}, snare={"model": 9, "tune": 0, "decay": 0.7}, metal={"level": 0},
            hatClosed={"model": 9, "tune": 12, "decay": 0.3}),
        [ringmod(180, 0.1, 0.3, 0.2), comp(-20, 8, 2, 60, 6), verb("gated", wet=0.25, gateTime=180)])
nin_kit("March of the Pigs Kit - 7/8 Stomp", "nin-march-of-the-pigs", 134, "Overdriven stomping kit for a frantic 7/8 feel.",
        kit(-3, kick={"decay": 0.9, "drive": 0.7, "snap": 0.9}, snare={"drive": 0.6, "snap": 0.9, "tone": 0.7}, crash={"decay": 1.5}),
        [dist("Distortion", 14, 7000, 30, -12), comp(-22, 8, 2, 70, 6), limiter(-0.8, 3)])
nin_kit("Pinion Kit - Distant Thunder", "nin-pinion", 72, "Sparse, huge, reverberant hits.",
        kit(-3, kick={"decay": 2, "tune": -6}, tomLow={"tune": -9, "decay": 2.5}, crash={"decay": 3.5}),
        [verb("cathedral", decay=6, wet=0.35), comp(-18, 3, 30, 300, 3)])
nin_kit("Head Like a Hole Kit - Driving Industrial", "nin-head-like-a-hole", 118, "Driving, punchy machine kit with clap-layered snare and tight hats.",
        kit(-2, kick={"tune": -1, "decay": 0.9, "drive": 0.4, "snap": 0.8}, snare={"snap": 0.8, "drive": 0.3}, clap={"level": -3}),
        [comp(-20, 5, 8, 100, 5), dist("Tape", 6, 9000, 20, -4), limiter(-0.8, 2)])
nin_kit("Starfuckers Kit - Glam Crunch", "nin-starfuckers", 128, "Fat swinging kick with crunchy, bitcrushed snare and hats.",
        kit(-2, kick={"decay": 1.0, "drive": 0.5}, snare={"tune": 3, "drive": 0.5, "snap": 0.8}, hatClosed={"drive": 0.4}),
        [bitcrush(11, 2, 0, 0.35), comp(-20, 6, 5, 90, 5), limiter(-0.8, 2)])

add("Hallows Eve - Deep Baritone Vocal", "Vocal", "Type O Negative",
    "Deep, cavernous baritone: warm low-mid EQ, slow chorus, octave-down doubling and a long dark gothic reverb.",
    [eq(lowCut=60, lowShelfFreq=150, lowShelfGain=3, peak2Freq=2500, peak2Gain=-2, highShelfFreq=9000, highShelfGain=-3),
     comp(-22, 3.5, 15, 180, 5), pitch(-12, 0, 60, 0.18, 6), doubler(22, 31, 10, 1.0, 0.45), chorus(0.3, 5, 18, 3, 0.15, 1.0, 0.35),
     verb("cathedral", size=0.95, decay=5.5, pre=40, damp=4200, wet=0.28)],
    tags=["vocal", "baritone", "gothic", "doubling", "Hallows Eve"], tempo=70)

add("Elite - Distorted Megaphone Vocal", "Vocal", "Deftones",
    "Screamed vocal with heavy distortion, band-limited megaphone filtering, gritty compression and a short slap.",
    [gate(-50, 50), comp(-26, 8, 2, 60, 8), dist("Distortion", 26, 4200, 350, -16),
     cab("Megaphone", 0.4, 400, 4200), eq(lowCut=300, peak2Freq=1500, peak2Gain=6, peak2Q=1.2, highCut=6500),
     delay(90, "off", 0.1, 0.15), verb("room", size=0.35, decay=0.6, wet=0.12)],
    tags=["vocal", "scream", "distorted", "megaphone", "Elite"])

# ============================== GENERAL PER-ARTIST PRESETS ==============================
# For each artist style: Vocal, Guitar, Bass, Keys, Drums, Synth.

def gen(artist, beat, tempo, vocal, guitar, bass, keys_, drums, synth_):
    for cat, (name, desc, effects, inst) in (("Vocal", vocal), ("Guitar", guitar), ("Bass", bass),
                                             ("Keys", keys_), ("Drums", drums), ("Synth", synth_)):
        add(f"{artist} - {name}", cat, artist, desc, effects, inst, tags=[cat.lower()],
            beat=beat if cat == "Drums" else None, tempo=tempo)

def bass_amp(model="Bass Amp", gain=4, drive=None, cabm="8x10 Bass"):
    chain = [comp(-20, 4, 15, 150, 4)]
    if drive:
        chain.append(dist(drive[0], drive[1], drive[2], 40, -10))
    chain += [amp(model, gain, bass=6, mid=5, treble=5, presence=4, tight=40), cab(cabm, 0.3, 35, 6000)]
    return chain

gen(NIN, "industrial", 110,
    ("Whisper to Scream Vocal", "Intimate close vocal that can explode; distortion parallel-blended.",
     [comp(-24, 6, 3, 80, 6), dist("Distortion", 18, 5000, 200, -12) | {"mix": 0.35}, eq(lowCut=90, peak3Freq=3500, peak3Gain=3),
      delay(120, "off", 0.1, 0.1), verb("plate", decay=1.4, wet=0.15)], None),
    ("Industrial Rhythm Guitar", "Fizzy, gated, hard-clipped rhythm guitar.",
     [gate(-50, 40), dist("Hard Clip", 28, 5500, 200, -14), amp("Modern Metal", 6, mid=4, treble=7), cab("4x12 Closed (V-type)", 0.25), bitcrush(12, 1, 0, 0.2)], None),
    ("Overdriven Synth-like Bass", "Bass guitar pushed into fuzz with synth-like sub weight.",
     bass_amp("Bass Amp", 6, ("Fuzz", 18, 3000)) + [octaver(1, 0.4, 0, 0, 500)], None),
    ("Broken Piano", "Detuned, lo-fi piano with bitcrush and room.",
     [bitcrush(12, 2, 0, 0.3), eq(lowCut=120, highCut=9000), verb("room", decay=1.2, wet=0.25)], keys("Piano", brightness=0.4, tune=-12, attackNoise=0.6)),
    ("Industrial Machine Kit", "Distorted, compressed drum machine.",
     [dist("Tape", 8, 8000, 20, -6), comp(-20, 6, 5, 90, 5), limiter(-1, 2)],
     kit(-3, kick={"drive": 0.5, "snap": 0.8}, snare={"drive": 0.4}, metal={"level": -3})),
    ("Distorted Mono Lead", "Aggressive saw lead with drive.",
     [dist("Distortion", 16, 6000, 100, -12), delay(300, "1/8d", 0.3, 0.2)], synth(osc1Wave=0, osc2Wave=0, osc2Detune=15, cutoff=3500, resonance=2, mono=1, glide=30, drive=0.4)))

gen("Paradise Lost", "doom", 80,
    ("Gothic Doom Vocal", "Dark baritone with plate and hall, subtle doubling.",
     [comp(-20, 4, 10, 150, 4), eq(lowCut=80, peak1Freq=250, peak1Gain=2), doubler(20, 28, 6, 0.8, 0.35), verb("hall", decay=3, wet=0.22)], None),
    ("Doom Rhythm Guitar", "Thick, slow, mid-heavy downtuned rhythm tone.",
     [gate(-55, 80), amp("British Lead", 7.5, bass=6, mid=6, treble=5, tight=110), cab("4x12 Greenback", 0.4, 70, 7000), verb("room", decay=0.8, wet=0.08)], None),
    ("Doom Bass", "Growling overdriven bass.", bass_amp("Bass Amp", 5, ("Overdrive", 12, 2500)), None),
    ("Gothic Organ", "Church-style organ with cathedral reverb.", [verb("cathedral", decay=5, wet=0.3)], keys("Organ", registration=5, modDepth=0.2)),
    ("Doom Kit", "Big, roomy, slow kit.", [comp(-18, 4, 20, 200, 3), verb("hall", decay=2, wet=0.15)],
     kit(-3, kick={"tune": -3, "decay": 1.3}, snare={"tune": -2, "decay": 1.3}, tomLow={"tune": -6, "decay": 2})),
    ("Gothic Strings", "Melancholic string machine pad.", [chorus(0.3, 5, 15, 3, 0.1, 1, 0.4), verb("hall", decay=4, wet=0.3)], keys("String Machine", attack=0.8, release=2, ensemble=0.8)))

gen("Soundgarden", "grunge", 104,
    ("Soaring Grunge Vocal", "Wide-range rock vocal with presence and plate.",
     [comp(-20, 4, 8, 120, 5), eq(lowCut=90, peak3Freq=3000, peak3Gain=3), delay(250, "1/8", 0.15, 0.1), verb("plate", decay=1.6, wet=0.15)], None),
    ("Drop-D Sludge Guitar", "Big fuzzy crunch for heavy drop-tuned riffs.",
     [dist("Fuzz", 14, 3500, 90, -12), amp("Crunch", 7, bass=6, mid=6, treble=5), cab("4x12 Greenback", 0.35)], None),
    ("Grunge Pick Bass", "Gritty pick bass.", bass_amp("Bass Amp", 6, ("Overdrive", 10, 3500)), None),
    ("Psychedelic Organ", "Rotary organ with phaser.", [phaser(0.3, 0.7, 700, 6, 0.4, 0.4), verb("room", decay=1, wet=0.2)], keys("Organ", registration=0, modRate=6.5, modDepth=0.6)),
    ("Grunge Live Kit", "Roomy, punchy acoustic-style kit.", [comp(-18, 4, 15, 150, 4), verb("room", size=0.6, decay=1.1, wet=0.2)],
     kit(-3, kick={"decay": 1.0}, snare={"decay": 1.1, "tone": 0.6}, crash={"decay": 2.8})),
    ("Swirling Synth Pad", "Phased drone pad.", [phaser(0.15, 0.8, 600, 8, 0.6, 0.5), verb("hall", decay=3.5, wet=0.3)], synth(osc1Wave=0, osc2Wave=2, cutoff=1500, ampA=1.5, ampR=2.5, unison=3)))

gen("Alice in Chains", "grunge", 92,
    ("Harmony Stack Vocal", "Dark, doubled lead with a haunting harmony fifth layer.",
     [comp(-22, 4, 8, 120, 5), doubler(16, 24, 9, 1, 0.5), pitch(7, 0, 50, 0.15, 5), verb("plate", decay=2, wet=0.18)], None),
    ("Wah Sludge Guitar", "Mid-scooped heavy tone with auto-wah colour.",
     [autowah(0, 0.5, 400, 2000, 4), amp("US High Gain", 6.5, bass=6, mid=4, treble=6), cab("4x12 Closed (V-type)", 0.35)], None),
    ("Dark Grind Bass", "Dark chorus-tinged bass.", bass_amp("Bass Amp", 5, ("Overdrive", 8, 2500)) + [chorus(0.5, 3, 10, 1, 0, 0.5, 0.25)], None),
    ("Moody Rhodes", "Dark tremolo Rhodes.", [tremolo(4, 0.3), verb("room", decay=1.4, wet=0.2)], keys("Rhodes", brightness=0.35, modDepth=0.3)),
    ("Heavy Groove Kit", "Thick, slower, deep kit.", [comp(-18, 4, 15, 150, 4), verb("room", decay=1.2, wet=0.18)],
     kit(-3, kick={"tune": -2, "decay": 1.2}, snare={"tune": -3, "decay": 1.2})),
    ("Dark Drone Synth", "Low droning saw pad.", [verb("hall", decay=4, wet=0.25)], synth(osc1Wave=0, osc1Octave=-1, cutoff=900, ampA=1, ampR=2)))

gen("Killing Joke", "industrial", 124,
    ("Shouted Post-Punk Vocal", "Raw shouted vocal with slap delay and grit.",
     [comp(-22, 6, 4, 80, 6), dist("Tube", 10, 5000, 200, -8), delay(110, "off", 0.15, 0.2), verb("room", decay=0.8, wet=0.15)], None),
    ("Tribal Post-Punk Guitar", "Bright, chorused, metallic distortion wall.",
     [dist("Distortion", 16, 6500, 200, -12), amp("Crunch", 6, mid=4, treble=7.5, presence=7), cab("2x12 Vintage", 0.2), chorus(0.6, 3, 10, 2, 0.1, 0.9, 0.35)], None),
    ("Dub Post-Punk Bass", "Deep, prominent dubby bass.", bass_amp("Bass Amp", 4) + [delay(380, "1/4", 0.2, 0.12, 0, 60, 1500)], None),
    ("Cold Synth Organ", "Thin cold organ.", [chorus(0.4, 3, 12, 2, 0.1, 1, 0.3), verb("plate", decay=1.8, wet=0.2)], keys("Organ", registration=3)),
    ("Tribal Floor Tom Kit", "Pounding tom-driven tribal kit.", [comp(-18, 5, 10, 120, 5), verb("room", decay=1, wet=0.15)],
     kit(-3, tomLow={"tune": -4, "decay": 1.8, "level": 0}, tomMid={"decay": 1.4}, kick={"decay": 1.0})),
    ("Apocalypse Synth", "Dark detuned brass-like synth.", [verb("hall", decay=3, wet=0.25)], synth(osc1Wave=0, osc2Wave=0, osc2Detune=10, cutoff=2000, filterEnv=0.5, ampA=0.05)))

gen("The Sisters of Mercy", "goth", 132,
    ("Gothic Crooner Vocal", "Deep, dry-but-dark crooner baritone with long plate.",
     [comp(-22, 4, 10, 150, 5), eq(lowShelfFreq=140, lowShelfGain=3, highShelfGain=-2), verb("plate", decay=2.8, wet=0.22), delay(420, "1/4", 0.2, 0.12)], None),
    ("Goth Chorus Guitar", "Clean-ish guitar drenched in chorus and delay.",
     [comp(-20, 3, 10, 120, 3), amp("Goth Clean", 4, treble=7), cab("2x12 Vintage", 0.3), chorus(0.7, 6, 14, 3, 0.2, 1, 0.55), delay(380, "1/8d", 0.4, 0.3, 1), verb("hall", decay=2.5, wet=0.2)], None),
    ("Driving Goth Bass", "Pick bass with chorus, upfront.", bass_amp("Bass Amp", 4) + [chorus(0.6, 4, 12, 2, 0.1, 0.6, 0.35)], None),
    ("Gothic Choir Strings", "Lush string machine.", [chorus(0.3, 6, 16, 3, 0.15, 1, 0.5), verb("cathedral", decay=4, wet=0.3)], keys("String Machine", attack=0.5, ensemble=0.9)),
    ("Doktor Machine Kit", "Fast, dry 80s drum machine with gated snare.", [comp(-18, 4, 5, 80, 3), verb("gated", wet=0.25)],
     kit(-3, kick={"model": 0, "decay": 0.7, "snap": 0.9}, snare={"tone": 0.7, "snap": 0.8}, hatClosed={"decay": 0.4})),
    ("Goth Synth Lead", "Cold square lead.", [delay(380, "1/4", 0.35, 0.25, 1), verb("hall", decay=3, wet=0.25)], synth(osc1Wave=1, osc2Wave=1, osc2Octave=1, cutoff=2500, mono=1)))

gen("Marilyn Manson", "industrial", 108,
    ("Snarling Shock Vocal", "Distorted, telephone-filtered snarl with doubling.",
     [comp(-24, 8, 2, 60, 7), dist("Distortion", 20, 4500, 300, -14), eq(lowCut=250, peak2Freq=1800, peak2Gain=5, highCut=8000), doubler(14, 22, 12, 1, 0.4)], None),
    ("Shock Rock Rhythm", "Thick, saturated, gated wall of guitar.",
     [gate(-48, 40), amp("Modern Metal", 7, bass=6, mid=4, treble=6.5), cab("4x12 Closed (V-type)", 0.3), eq(peak2Freq=700, peak2Gain=-3)], None),
    ("Fuzz-Synth Bass", "Heavy fuzz bass with octave down.", bass_amp("Fuzz Stack", 6) + [octaver(1, 0.5, 0, 0, 600)], None),
    ("Creepy Music Box Keys", "Detuned harpsichord with flanger.", [flanger(0.1, 0.5, 3, 0.4, 0.3), verb("hall", decay=3, wet=0.3)], keys("Harpsichord", tune=-20, brightness=0.7)),
    ("Industrial Glam Kit", "Stomping, distorted kit with claps.", [dist("Tape", 8, 8000, 20, -6), comp(-20, 6, 5, 80, 5)],
     kit(-3, kick={"drive": 0.6}, snare={"drive": 0.4}, clap={"level": -2})),
    ("Noise Synth Stab", "Ring-modulated noise stab.", [ringmod(400, 0.2, 0.5, 0.4), dist("Fuzz", 20, 6000, 100, -14)], synth(osc1Wave=0, noiseLevel=0.4, cutoff=4000, ampD=0.2, ampS=0)))

gen("Duran Duran", "new-wave", 120,
    ("New Romantic Vocal", "Polished, bright vocal with chorus and plate.",
     [comp(-20, 4, 8, 120, 5), eq(lowCut=100, highShelfFreq=8000, highShelfGain=3), chorus(0.5, 2, 12, 2, 0.05, 0.8, 0.2), verb("plate", decay=2, wet=0.2)], None),
    ("Funky New Wave Clean", "Bright, compressed, chorused funk guitar.",
     [comp(-24, 5, 5, 90, 6), amp("Clean", 3, treble=7.5, presence=7), cab("1x12 Open Back", 0.2), chorus(0.8, 4, 10, 2, 0.1, 1, 0.45), verb("room", decay=1, wet=0.15)], None),
    ("Slap Funk Bass", "Bright punchy fretless/slap-style tone.",
     [comp(-24, 6, 3, 80, 6), eq(lowShelfGain=3, peak3Freq=2500, peak3Gain=4), chorus(0.5, 2, 8, 1, 0, 0.4, 0.2)], None),
    ("80s Poly Brass Synth", "Polysynth brass stabs.", [chorus(0.6, 3, 12, 2, 0.1, 1, 0.4), verb("plate", decay=1.5, wet=0.2)],
     synth(osc1Wave=0, osc2Wave=0, osc2Detune=8, cutoff=1800, filterEnv=0.55, filtA=0.04, filtD=0.4, ampA=0.02)),
    ("New Wave Drum Machine", "Gated, punchy 80s machine.", [comp(-18, 4, 5, 80, 4), verb("gated", wet=0.3)],
     kit(-3, kick={"decay": 0.8}, snare={"tone": 0.65, "decay": 1.1}, tomHigh={"tune": 7}, clap={"level": -4})),
    ("Arpeggio Synth", "Bright plucky arp synth.", [delay(250, "1/8", 0.35, 0.25, 1), verb("hall", decay=2, wet=0.2)],
     synth(osc1Wave=1, osc2Wave=0, cutoff=2200, filterEnv=0.6, filtD=0.15, filtS=0, ampD=0.3, ampS=0.2)))

gen("Deftones", "nu-metal", 100,
    ("Dreamy Whisper Vocal", "Airy, breathy vocal with shimmer.",
     [comp(-22, 4, 8, 150, 5), eq(lowCut=120, highShelfFreq=10000, highShelfGain=4), delay(380, "1/4", 0.3, 0.18, 1), verb("shimmer", decay=4, wet=0.22)], None),
    ("Baritone Wall Guitar", "Huge, dark baritone 7-string wall.",
     [gate(-52, 50), amp("US High Gain", 6, bass=7, mid=4, treble=5, tight=70), cab("4x12 Closed (V-type)", 0.45, 60, 7000), verb("ambient", decay=3, wet=0.12)], None),
    ("Thick Nu Bass", "Gritty, mid-forward bass.", bass_amp("Bass Amp", 6, ("Distortion", 10, 3000)), None),
    ("Ethereal Keys", "Washed-out electric piano.", [chorus(0.4, 5, 14, 2, 0.1, 1, 0.4), verb("ambient", decay=6, wet=0.35)], keys("Electric Piano", brightness=0.3)),
    ("Deftones Groove Kit", "Punchy, roomy, tight snare.", [comp(-18, 4, 10, 120, 4), verb("room", decay=1, wet=0.15)],
     kit(-3, kick={"decay": 1.0, "snap": 0.7}, snare={"tone": 0.6, "snap": 0.7})),
    ("Shoegaze Pad", "Reverse-reverb drenched pad.", [verb("reverse", wet=0.4), verb("ambient", decay=7, wet=0.3)], synth(osc1Wave=0, osc2Wave=2, unison=4, cutoff=2000, ampA=1.2, ampR=3)))

gen("KoRn", "nu-metal", 98,
    ("Nu-Metal Scat Vocal", "Tight, compressed, mid-heavy vocal with grit.",
     [comp(-24, 8, 3, 70, 7), dist("Overdrive", 8, 5000, 150, -6), eq(peak2Freq=1200, peak2Gain=3), verb("room", decay=0.7, wet=0.12)], None),
    ("7-String Drop-A Riff", "Scooped, bass-heavy, tight 7-string chug.",
     [gate(-50, 40), dist("Overdrive", 6, 4000, 500, -6), amp("Modern Metal", 7, bass=7.5, mid=2.5, treble=6.5, tight=150), cab("4x12 Closed (V-type)", 0.3)], None),
    ("Clacky 5-String Bass", "Bright, clanky slap-attack bass.",
     [comp(-22, 6, 2, 60, 6), eq(lowShelfGain=4, peak2Freq=500, peak2Gain=-4, peak3Freq=3000, peak3Gain=6), dist("Overdrive", 6, 6000, 40, -4)], None),
    ("Eerie Bell Keys", "Detuned, eerie Rhodes bell.", [flanger(0.1, 0.4, 3, 0.3, 0.25), verb("hall", decay=3, wet=0.25)], keys("Rhodes", brightness=0.7, tune=-15)),
    ("Nu-Metal Kit", "Ping-y, tight snare, clicky kick.", [comp(-20, 5, 5, 80, 5), verb("room", decay=0.7, wet=0.12)],
     kit(-3, kick={"snap": 1, "tone": 0.7}, snare={"tune": 4, "tone": 0.75, "decay": 0.7})),
    ("Haunted Synth", "Creepy wobbly lead.", [verb("hall", decay=3, wet=0.3)], synth(osc1Wave=3, osc2Wave=2, lfoRate=6, lfoPitch=0.4, cutoff=3000, mono=1, glide=80)))

gen("Tori Amos", "alt-rock", 90,
    ("Intimate Piano Vocal", "Natural, close, airy vocal with chamber reverb.",
     [comp(-20, 3, 10, 150, 3), eq(lowCut=80, highShelfFreq=10000, highShelfGain=3), verb("chamber", decay=1.8, wet=0.2)], None),
    ("Acoustic-ish Clean Guitar", "Clean, bright, natural guitar.", [comp(-18, 3, 10, 120, 3), amp("Clean", 2, treble=6.5), cab("1x12 Open Back", 0.2), verb("chamber", decay=1.5, wet=0.15)], None),
    ("Warm Upright-style Bass", "Round, warm, soft bass.", [comp(-18, 3, 20, 200, 3), eq(lowShelfGain=2, highCut=4000)], None),
    ("Bösendorfer-style Grand", "Expressive, bright grand piano.", [comp(-16, 2, 20, 200, 2), verb("hall", decay=2.2, wet=0.18)], keys("Piano", brightness=0.65, decay=1.4, velocity=0.95)),
    ("Soft Brushes Kit", "Light, gentle kit.", [comp(-18, 3, 20, 200, 2), verb("chamber", decay=1.4, wet=0.2)],
     kit(-6, kick={"decay": 0.8, "tone": 0.3}, snare={"tone": 0.3, "snap": 0.3}, ride={"level": -6})),
    ("Harpsichord Baroque", "Bright harpsichord for baroque colours.", [verb("chamber", decay=1.6, wet=0.2)], keys("Harpsichord", brightness=0.6)))

gen("The Smashing Pumpkins", "alt-rock", 112,
    ("Nasal Alt Vocal", "Bright, nasal, upfront vocal.",
     [comp(-22, 5, 5, 100, 6), eq(lowCut=120, peak2Freq=1500, peak2Gain=3, peak3Freq=4000, peak3Gain=2), verb("room", decay=1, wet=0.15)], None),
    ("Big Muff Wall Guitar", "Thick, sustaining fuzz wall, doubled wide.",
     [dist("Fuzz", 30, 3000, 60, -16), amp("Crunch", 5, bass=6, mid=4, treble=6), cab("4x12 Greenback", 0.35), doubler(15, 25, 6, 1, 0.6)], None),
    ("Fuzzy Pick Bass", "Overdriven bass with presence.", bass_amp("Bass Amp", 5, ("Fuzz", 10, 3000)), None),
    ("Mellotron-ish Strings", "Wobbly tape strings.", [chorus(0.2, 6, 15, 2, 0.1, 0.8, 0.4), verb("hall", decay=3, wet=0.25)], keys("String Machine", attack=0.3, ensemble=0.6)),
    ("Alt-Rock Big Kit", "Huge, open-room rock kit.", [comp(-18, 4, 15, 150, 4), verb("room", size=0.7, decay=1.3, wet=0.2)],
     kit(-3, kick={"decay": 1.1}, snare={"decay": 1.2, "tone": 0.55}, crash={"decay": 3})),
    ("Dreamy Phase Synth", "Phased pad.", [phaser(0.2, 0.8, 700, 8, 0.5, 0.5), verb("hall", decay=3, wet=0.3)], synth(osc1Wave=0, osc2Wave=0, unison=3, cutoff=1800, ampA=0.8, ampR=2)))

gen("Type O Negative", "doom", 72,
    ("Gothic Baritone Vocal", "Very deep baritone with chorus and long reverb.",
     [comp(-20, 3, 15, 180, 4), eq(lowShelfFreq=150, lowShelfGain=3), chorus(0.25, 5, 18, 3, 0.15, 1, 0.3), verb("cathedral", decay=5, wet=0.25)], None),
    ("Green Flanged Doom Guitar", "Fuzzy, sludgy, flanged doom guitar.",
     [dist("Fuzz", 18, 3000, 70, -12), amp("Crunch", 6, bass=7, mid=5, treble=4.5), cab("4x12 Greenback", 0.45), flanger(0.12, 0.6, 3, 0.5, 0.35)], None),
    ("Fuzz-Flange Bass", "Heavily overdriven flanged bass.", bass_amp("Fuzz Stack", 6) + [flanger(0.1, 0.5, 3, 0.4, 0.3)], None),
    ("Gothic Church Organ", "Huge organ in a cathedral.", [verb("cathedral", decay=6, wet=0.35)], keys("Organ", registration=4, modRate=1, modDepth=0.3)),
    ("Slow Doom Kit", "Huge, slow, reverberant kit.", [comp(-18, 4, 20, 200, 3), verb("hall", decay=2.5, wet=0.2)],
     kit(-3, kick={"tune": -4, "decay": 1.4}, snare={"tune": -4, "decay": 1.5}, tomLow={"tune": -8, "decay": 2.2})),
    ("Gothic Strings Synth", "Dark, chorused string synth.", [chorus(0.3, 6, 18, 3, 0.1, 1, 0.4), verb("cathedral", decay=5, wet=0.3)],
     synth(osc1Wave=0, osc2Wave=0, osc2Detune=12, unison=4, cutoff=1500, ampA=1, ampR=3)))

# ============================== GENERIC STARTER PRESETS ==============================
add("Clean Vocal Starter", "Vocal", "", "Neutral vocal chain: low cut, gentle compression, plate.",
    [eq(lowCut=90), comp(-18, 3, 10, 120, 3), verb("plate", decay=1.5, wet=0.15)], tags=["starter"])
add("Clean Guitar Starter", "Guitar", "", "Simple clean amp and cab.", [amp("Clean", 3), cab("2x12 Vintage")], tags=["starter"])
add("Bass DI Starter", "Bass", "", "Compressed DI bass.", [comp(-20, 4, 15, 150, 4), eq(lowCut=35)], tags=["starter"])
add("Piano Starter", "Keys", "", "Plain piano.", [verb("room", decay=1.2, wet=0.15)], keys("Piano"), tags=["starter"])
add("Drum Machine Starter", "Drums", "", "Default synthesized kit.", [comp(-18, 3, 10, 120, 2)], kit(), tags=["starter"], beat="alt-rock")
add("Synth Starter", "Synth", "", "Init subtractive synth.", [], synth(), tags=["starter"])
add("Bass Synth Starter", "Bass", "", "Init bass synth.", [], synth("synth.bass"), tags=["starter", "synth"])
add("Trumpet Starter", "Synth", "", "Plain open trumpet.", [verb("room", decay=1, wet=0.15)], brass(), tags=["starter", "brass"])
add("Spring Reverb Surf", "Guitar", "", "Clean amp with drippy spring reverb and tremolo.", [amp("Clean", 3, treble=7), cab("1x12 Open Back"), tremolo(6, 0.5), spring(2.5, 0.5, 3500, 0.8, 0.4)], tags=["spring", "surf"])
add("Convolution Room Vocal", "Vocal", "", "Vocal through the convolution reverb (load your own IR in the effect).",
    [comp(-18, 3, 10, 120, 3), conv(1, 1.5, 10, 0.25)], tags=["convolution", "ir"])


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    ids = set()
    for p in PRESETS:
        assert p["id"] not in ids, "duplicate id " + p["id"]
        ids.add(p["id"])
        with open(os.path.join(OUT, p["id"] + ".json"), "w", encoding="utf-8") as f:
            json.dump(p, f, indent=2, ensure_ascii=False)
            f.write("\n")
    print(f"Wrote {len(PRESETS)} presets to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
