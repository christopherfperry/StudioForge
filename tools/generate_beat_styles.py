#!/usr/bin/env python3
"""
Generates Fitzrovia Records DAW's bundled beat styles into Sources/SFBeatGen/Resources/BeatStyles.
Each style is a plain JSON file you can edit by hand. Step-string legend:
  X accent   x hit   o ghost   ? optional (plays with probability = complexity)   . rest   | and spaces ignored
These are original patterns written for Fitzrovia Records DAW "in the style of" a genre/artist.
"""
import json
import os
import shutil

OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "SFBeatGen", "Resources", "BeatStyles")
STYLES = []

def style(id, name, genre, lanes, artist="", desc="", tempo=110, rng=(90, 130), swing=0.0, ts=(4, 4), steps=16,
          complex_lanes=None, fills=None, accent=("crash",), kit=None):
    STYLES.append({
        "id": id, "name": name, "genre": genre, "artistStyle": artist, "description": desc,
        "timeSignature": {"numerator": ts[0], "denominator": ts[1]}, "stepsPerBar": steps,
        "tempoRange": list(rng), "defaultTempo": tempo, "defaultSwing": swing,
        "lanes": lanes, "complexLanes": complex_lanes or {}, "fills": fills or [], "phraseAccent": list(accent),
        **({"kitPreset": kit} if kit else {}),
    })

TOM_FILL = {"snare": "....|....|x.x.|xxxx", "tomHigh": "x.x.|....|....|....", "tomMid": "....|x.x.|....|....", "tomLow": "....|....|....|....", "kick": "x...|x...|x...|x..."}
SNARE_ROLL = {"snare": "x.x.|x.x.|xxxx|XXXX", "kick": "x...|x...|x...|x...", "hatClosed": "................"}
TOM_RUN = {"tomHigh": "....|....|xx..|....", "tomMid": "....|....|..xx|....", "tomLow": "....|....|....|xxXX", "snare": "x...|x...|....|....", "kick": "x...|x...|x...|x..."}

# ----------------------------- Genre styles -----------------------------
style("industrial", "Industrial Stomp", "Industrial",
      {"kick": "X...|..x.|X...|..x.", "snare": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x.", "metal": "....|....|....|...?"},
      desc="Mechanical four-on-the-floor-ish stomp with metallic accents.", tempo=112, rng=(95, 135),
      complex_lanes={"hatClosed": "xoxo|xoxo|xoxo|xoxo", "kick": "....|....|....|.?..", "clap": "....|?...|....|x..."},
      fills=[SNARE_ROLL, {"metal": "x.x.|x.x.|xxxx|xxxx", "kick": "x...|x...|x...|x..."}])
style("doom", "Doom Crawl", "Doom",
      {"kick": "X.......|........", "snare": "........|X.......", "ride": "x...x...|x...x...", "crash": "X.......|........"},
      desc="Slow, heavy half-time doom crawl (two-bar pattern over 8th-note grid).", tempo=70, rng=(55, 90), steps=8,
      complex_lanes={"kick": "...?..x.|..?.....", "tomLow": "........|......?."},
      fills=[{"tomHigh": "x.x.....", "tomMid": "....x.x.", "tomLow": "........", "snare": "........"},
             {"snare": "x...x.xx", "tomLow": "..x....."}], accent=())
style("grunge", "Grunge Rock", "Grunge",
      {"kick": "X...|..x.|x.x.|....", "snare": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x."},
      desc="Loose, heavy alt-rock groove with open hats.", tempo=104, rng=(85, 130), swing=0.1,
      complex_lanes={"hatOpen": "....|....|....|..?.", "snare": "....|...o|..o.|...o", "kick": "....|....|....|.?.."},
      fills=[TOM_FILL, TOM_RUN])
style("goth", "Goth Drum Machine", "Goth",
      {"kick": "X...|x...|X...|x...", "snare": "....|X...|....|X...", "hatClosed": "xxxx|xxxx|xxxx|xxxx"},
      desc="Driving 80s goth drum-machine pulse: straight kicks, relentless 16th hats, big snare.", tempo=132, rng=(115, 150),
      complex_lanes={"hatOpen": "..x.|..x.|..x.|..x.", "tomMid": "....|....|....|..??"},
      fills=[{"tomHigh": "x.x.|....|....|....", "tomMid": "....|x.x.|....|....", "tomLow": "....|....|x.x.|x.x.", "hatClosed": "................"}, SNARE_ROLL])
style("nu-metal", "Nu-Metal Bounce", "Nu-Metal",
      {"kick": "X..x|..x.|.x..|x...", "snare": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x."},
      desc="Syncopated, bouncy nu-metal groove with ghosted snares.", tempo=98, rng=(85, 115), swing=0.15,
      complex_lanes={"snare": "..o.|...o|o...|..o.", "hatOpen": "....|....|....|..x.", "china": "....|....|....|...?"},
      fills=[TOM_RUN, {"snare": "x..x|..x.|x.x.|XXXX", "kick": "x..x|..x.|x.x.|...."}])
style("new-wave", "New Wave Motorik", "New Wave",
      {"kick": "X...|x...|X...|x...", "snare": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x.", "hatOpen": "..x.|..x.|..x.|..x."},
      desc="Bright, upbeat new-wave beat with open-hat offbeats and gated snare.", tempo=120, rng=(105, 145),
      complex_lanes={"clap": "....|x...|....|x...", "tambourine": "x.x.|x.x.|x.x.|x.x.", "tomHigh": "....|....|....|..?."},
      fills=[{"tomHigh": "....|....|xx..|....", "tomMid": "....|....|..xx|....", "tomLow": "....|....|....|xx..", "snare": "x...|x...|....|..XX"}])
style("alt-rock", "Alt-Rock Drive", "Alt-Rock",
      {"kick": "X...|....|x.x.|....", "snare": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x."},
      desc="Straight-ahead 90s alt-rock beat.", tempo=112, rng=(90, 140),
      complex_lanes={"kick": "....|..?.|....|.?..", "snare": "....|...o|....|..o.", "ride": "x.x.|x.x.|x.x.|x.x."},
      fills=[TOM_FILL, SNARE_ROLL, TOM_RUN])
style("goth-tribal", "Tribal Post-Punk", "Goth", artist="Killing Joke",
      lanes={"tomLow": "X..x|..x.|X..x|..x.", "kick": "X...|....|X...|....", "snare": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x."},
      desc="Pounding floor-tom tribal post-punk.", tempo=124, rng=(110, 140),
      complex_lanes={"tomMid": "..?.|....|..?.|....", "cowbell": "x...|x...|x...|x..."}, fills=[TOM_RUN])
style("doom-goth", "Gothic Doom Waltz", "Doom", artist="Type O Negative",
      lanes={"kick": "X.....|......", "snare": "......|X.....", "ride": "x.x.x.|x.x.x.", "crash": "X.....|......"},
      desc="Slow, heavy 6/8 gothic doom sway.", tempo=66, rng=(50, 85), ts=(6, 8), steps=6,
      complex_lanes={"kick": "...?..|..?..."}, fills=[{"tomHigh": "x.x...", "tomMid": "...x..", "tomLow": "....xx"}], accent=())

# ----------------------------- NIN-style templates -----------------------------
NIN = "Nine Inch Nails"
style("nin-closer", "Closer Groove", "Industrial", artist=NIN,
      lanes={"kick": "X...|...x|..X.|....", "snare": "....|X...|....|X...", "hatClosed": "x.xx|x.x.|x.xx|x.x."},
      desc="Dry, heavy-kick industrial-funk groove around 92 BPM (Closer-style; original pattern).", tempo=92, rng=(86, 98), swing=0.08,
      complex_lanes={"hatClosed": "xoxx|xox.|xoxx|xoxo", "snare": "....|...o|....|.o.."},
      fills=[{"snare": "....|....|..x.|x.XX", "kick": "x...|...x|..x.|x..."}], accent=(), kit="closer-kit-dry-heavy-kick")
style("nin-reptile", "Reptile Grind", "Industrial", artist=NIN,
      lanes={"kick": "X..x|..x.|X..x|....", "snare": "....|X...|....|X..x", "hatClosed": "x.x.|x.x.|x.x.|x.x.", "metal": "..x.|....|..x.|...."},
      desc="Grinding, lurching machine groove (Reptile-style; original pattern).", tempo=100, rng=(90, 110),
      complex_lanes={"metal": "..x.|..?.|..x.|.?.?", "clap": "....|X...|....|X..."},
      fills=[{"metal": "x.x.|x.x.|xxxx|xxxx", "snare": "....|....|x.x.|xxxx"}], kit="reptile-kit-crushed-machine")
style("nin-eraser", "Eraser Build", "Industrial", artist=NIN,
      lanes={"tomLow": "X...|..x.|X...|..x.", "tomMid": "....|x...|....|x...", "kick": "X...|....|X...|...."},
      desc="Tribal tom build that thickens with complexity (Eraser-style; original pattern).", tempo=84, rng=(76, 92),
      complex_lanes={"snare": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x.", "kick": "..?.|..?.|..?.|..?."},
      fills=[TOM_RUN], kit="eraser-kit-building-tribal")
style("nin-happiness-in-slavery", "Happiness in Slavery Machine", "Industrial", artist=NIN,
      lanes={"kick": "X...|X...|X...|X...", "snare": "....|X...|....|X...", "hatClosed": "xxxx|xxxx|xxxx|xxxx", "metal": "x..x|..x.|x..x|..x."},
      desc="Rigid, clanking, quantised machine beat (Happiness in Slavery-style; original pattern).", tempo=120, rng=(110, 132),
      complex_lanes={"metal": "x..x|.xx.|x..x|.xxx", "cowbell": "..x.|..x.|..x.|..x."},
      fills=[{"metal": "xxxx|xxxx|xxxx|XXXX", "snare": "....|....|....|x.x."}], kit="happiness-in-slavery-kit-mechanical")
style("nin-march-of-the-pigs", "March of the Pigs 7/8 Stomp", "Industrial", artist=NIN,
      lanes={"kick": "X.x.|..x.|X...|..", "snare": "....|X...|..X.|..", "hatClosed": "x.x.|x.x.|x.x.|x.", "crash": "X...|....|....|.."},
      desc="Frantic stomp in 7/8 (14 sixteenths per bar; March of the Pigs-style; original pattern).", tempo=134, rng=(120, 150),
      ts=(7, 8), steps=14,
      complex_lanes={"snare": "....|...o|....|.o", "china": "....|....|....|?."},
      fills=[{"snare": "x.x.|x.x.|xxxx|XX", "kick": "x...|x...|x...|x."}], accent=(), kit="march-of-the-pigs-kit-7-8-stomp")
style("nin-pinion", "Pinion Thunder", "Industrial", artist=NIN,
      lanes={"kick": "X.......|........", "tomLow": "........|X.......", "crash": "X.......|........"},
      desc="Sparse, huge hits that leave space (Pinion-style; original pattern).", tempo=72, rng=(60, 84), steps=8,
      complex_lanes={"snare": "........|....X...", "tomMid": "......?.|......?."}, fills=[{"tomLow": "x.x.xxXX", "kick": "x...x..."}], accent=(),
      kit="pinion-kit-distant-thunder")
style("nin-head-like-a-hole", "Head Like a Hole Drive", "Industrial", artist=NIN,
      lanes={"kick": "X...|..x.|X.x.|....", "snare": "....|X...|....|X...", "clap": "....|x...|....|x...", "hatClosed": "xxxx|xxxx|xxxx|xxxx"},
      desc="Driving, punchy industrial dance-rock beat (Head Like a Hole-style; original pattern).", tempo=118, rng=(110, 126),
      complex_lanes={"hatOpen": "..x.|..x.|..x.|..x.", "kick": "....|....|....|..?."},
      fills=[SNARE_ROLL, TOM_RUN], kit="head-like-a-hole-kit-driving-industrial")
style("nin-starfuckers", "Starfuckers Swagger", "Industrial", artist=NIN,
      lanes={"kick": "X..x|..x.|X..x|.x..", "snare": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x."},
      desc="Swaggering, swung glam-industrial groove (Starfuckers, Inc.-style; original pattern).", tempo=128, rng=(116, 136), swing=0.2,
      complex_lanes={"tambourine": "..x.|..x.|..x.|..x.", "snare": "...o|....|..o.|...."},
      fills=[{"snare": "....|x.x.|xxxx|XXXX", "kick": "x..x|..x.|x...|...."}], kit="starfuckers-kit-glam-crunch")

# Artist templates for the other artists
style("smashing-pumpkins", "Pumpkins Pounding Rock", "Alt-Rock", artist="The Smashing Pumpkins",
      lanes={"kick": "X.x.|..x.|x.x.|..x.", "snare": "....|X...|....|X...", "ride": "x.x.|x.x.|x.x.|x.x."},
      desc="Busy, powerful alt-rock beat with driving kicks.", tempo=116, rng=(100, 140),
      complex_lanes={"snare": "..o.|...o|.o..|..o.", "tomLow": "....|....|....|..??"}, fills=[TOM_RUN, TOM_FILL])
style("sisters-machine", "Doktor Machine Pulse", "Goth", artist="The Sisters of Mercy",
      lanes={"kick": "X...|X...|X...|X...", "snare": "....|X...|....|X...", "hatClosed": "xxxx|xxxx|xxxx|xxxx", "tomHigh": "....|....|....|..x."},
      desc="Relentless fast goth drum-machine pulse.", tempo=138, rng=(125, 150),
      complex_lanes={"tomMid": "....|....|....|...x", "hatOpen": "..x.|....|..x.|...."}, fills=[{"tomHigh": "....|....|xx..|....", "tomMid": "....|....|..xx|....", "tomLow": "....|....|....|xxxx"}])
style("deftones-groove", "Deftones Half-Time Groove", "Nu-Metal", artist="Deftones",
      lanes={"kick": "X...|...x|..x.|....", "snare": "....|....|X...|....", "hatClosed": "x.x.|x.x.|x.x.|x.x."},
      desc="Spacious half-time groove with syncopated kicks.", tempo=100, rng=(85, 115),
      complex_lanes={"snare": "...o|..o.|....|.o..", "hatOpen": "....|..x.|....|..x."}, fills=[TOM_RUN])
style("korn-bounce", "KoRn Bounce", "Nu-Metal", artist="KoRn",
      lanes={"kick": "X.xx|..x.|.xx.|x...", "snare": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x."},
      desc="Choppy, bouncy nu-metal stutter groove.", tempo=98, rng=(85, 110), swing=0.2,
      complex_lanes={"snare": "..o.|..oo|o...|..o.", "china": "x...|....|x...|...."}, fills=[{"snare": "x.xx|.x.x|x.xx|XXXX"}])
style("duran-dance", "New Romantic Dance", "New Wave", artist="Duran Duran",
      lanes={"kick": "X...|x...|X...|x...", "snare": "....|X...|....|X...", "hatClosed": "xoxo|xoxo|xoxo|xoxo", "clap": "....|x...|....|x..."},
      desc="Danceable, glossy new-wave beat.", tempo=120, rng=(110, 132), swing=0.05,
      complex_lanes={"hatOpen": "..x.|..x.|..x.|..x.", "tambourine": "....|x...|....|x..."}, fills=[TOM_RUN])
style("soundgarden-heavy", "Heavy Grunge Shuffle", "Grunge", artist="Soundgarden",
      lanes={"kick": "X...|..x.|x...|x...", "snare": "....|X...|....|X...", "ride": "x.x.|x.x.|x.x.|x.x."},
      desc="Heavy, slightly swung grunge groove.", tempo=100, rng=(80, 120), swing=0.25,
      complex_lanes={"snare": "....|..o.|....|.o.o"}, fills=[TOM_FILL])
style("aic-sludge", "Sludgy Grunge Groove", "Grunge", artist="Alice in Chains",
      lanes={"kick": "X...|...x|x...|....", "snare": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x."},
      desc="Slow, heavy, dragging grunge groove.", tempo=90, rng=(75, 105), swing=0.1,
      complex_lanes={"hatOpen": "....|....|....|..x.", "snare": "....|....|..o.|...."}, fills=[TOM_RUN])
style("paradise-lost-doom", "Gothic Doom March", "Doom", artist="Paradise Lost",
      lanes={"kick": "X...|..x.|X...|....", "snare": "....|X...|....|X...", "ride": "x...|x...|x...|x..."},
      desc="Mid-tempo gothic doom march.", tempo=88, rng=(70, 100),
      complex_lanes={"kick": "....|....|..x.|..x.", "tomLow": "....|....|....|...?"}, fills=[TOM_FILL])
style("manson-stomp", "Shock Rock Stomp", "Industrial", artist="Marilyn Manson",
      lanes={"kick": "X...|....|X.x.|....", "snare": "....|X...|....|X...", "clap": "....|X...|....|X...", "hatClosed": "x.x.|x.x.|x.x.|x.x."},
      desc="Stomping, glam-industrial beat.", tempo=108, rng=(95, 120),
      complex_lanes={"metal": "....|..?.|....|..x."}, fills=[SNARE_ROLL])
style("tori-ballad", "Piano Ballad Brushes", "Alt-Rock", artist="Tori Amos",
      lanes={"kick": "x...|....|..x.|....", "rim": "....|x...|....|x...", "ride": "x.x.|x.x.|x.x.|x.x."},
      desc="Gentle ballad pattern with rim clicks.", tempo=80, rng=(60, 100), swing=0.15,
      complex_lanes={"kick": "....|...?|....|....", "snare": "....|...o|....|.o.."}, fills=[{"tomHigh": "....|....|..x.|x...", "tomLow": "....|....|....|..x."}], accent=())


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    for s in STYLES:
        with open(os.path.join(OUT, s["id"] + ".json"), "w", encoding="utf-8") as f:
            json.dump(s, f, indent=2)
            f.write("\n")
    print(f"Wrote {len(STYLES)} beat styles to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
