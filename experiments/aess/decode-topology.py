#!/usr/bin/env python3
"""decode-topology.py -- read the AESS firmware's DAPM graph out of the blob.

    ./decode-topology.py /lib/firmware/omap_aess-adfw.bin [--routes|--widgets]

The container (see patch 0014) carries the ABE's whole ASoC topology, not just
the firmware images. 0014 loads the two vendor blocks and skips the rest; 0015
recovered the MIXER block's 26 controls. This decodes the two remaining blocks,
which hold the DAPM graph -- the piece still missing before audio can flow,
because without widgets and routes DPCM finds no path from a front end to a
back end and open() returns -EINVAL.

ROUTES (block type 2) are fully decoded and the decode is exact:

    u32 count, then count * { char sink[32]; char control[32]; char source[32]; }

4 + 205*96 == 19684, the block's own size, to the byte. 205 routes, including
the downlink path this whole exercise is about:

    {"DL1 Mixer", "Multimedia", "MM_DL"}    {"PDM_DL1", "", "DL1 PDM"}
    {"DL1 PDM",   "Switch",     "Sidetone Mixer"}
    {"PDM_DL2",   "",           "DL2 Mixer"}    {"BE_OUT", "", "PDM_DL1"}

WIDGETS (block type 3) are fully decoded:

    u32 count, then count * { u32 id; char name[32]; char sname[32];
                              u32 reg, shift, x, y, num_kcontrols;
                              <num_kcontrols embedded kcontrols> }

count is 46 and all 46 walk to exactly the block's end. The embedded
kcontrols carry no size word, so their length comes from the widget type:

    a mux's enum kcontrol  1088 bytes = name[32] + 8*u32 + 32 text slots[32]
    everything else           80 bytes per switch kcontrol

Those two numbers are not guesses; they are the observed distances between
consecutive widget headers -- MUX_UL00 to MUX_UL01 is 1176 = 88 + 1088, and
DL1 Mixer to DL2 Mixer is 408 = 88 + 4*80 -- and with them the walk lands on
16532, the block's own size, to the byte.

The `id` is a snd_soc_dapm_type from before regulator_supply was added to that
enum, which shifts everything after snd_soc_dapm_supply down by one:

    2 = mux    3 = virt_mux    5 = mixer    21 = aif_in    22 = aif_out

That reading is what makes every widget make sense -- MM_DL and TONES_DL as
aif_in, PDM_DL1 and MM_UL1 as aif_out, MUX_UL00 as a mux -- and the decoded
kcontrol names confirm it independently: DL1 Mixer comes out carrying
{Tones, Voice, Capture, Multimedia}, which is exactly the set of `control`
strings the routes use when they sink into DL1 Mixer. Two separate blocks,
decoded by different rules, agreeing.
"""
import struct, sys, re

def blocks(path):
    d = open(path, "rb").read()
    off, out = 0, {}
    while off < len(d):
        magic, abi, typ, vtype, ver, size = struct.unpack_from("<6I", d, off)
        if magic != 0x41536F43:
            raise SystemExit("not an AESS container (bad magic at 0x%x)" % off)
        out.setdefault(typ, []).append(d[off + 24:off + 24 + size])
        off += 24 + size
    if off != len(d):
        raise SystemExit("container does not end at EOF")
    return out

def s32(b, o):
    return b[o:o + 32].split(b"\0")[0].decode(errors="replace")

def routes(b):
    n = struct.unpack_from("<I", b, 0)[0]
    if 4 + n * 96 != len(b):
        raise SystemExit("route block is %d bytes, %d routes want %d"
                         % (len(b), n, 4 + n * 96))
    return [(s32(b, 4 + i * 96), s32(b, 36 + i * 96), s32(b, 68 + i * 96))
            for i in range(n)]

TYPES = {0: "input", 1: "output", 2: "mux", 3: "virt_mux", 5: "mixer",
         21: "aif_in", 22: "aif_out"}
KCONTROL_SIZE = {2: 1088}          # a mux's enum; every other kcontrol is 80

def widgets(b):
    n = struct.unpack_from("<I", b, 0)[0]
    out, o = [], 4
    while len(out) < n and o + 88 <= len(b):
        wid = struct.unpack_from("<I", b, o)[0]
        nk = struct.unpack_from("<I", b, o + 84)[0]
        ks = KCONTROL_SIZE.get(wid, 80)
        kc = [s32(b, o + 88 + k * ks) for k in range(nk)]
        out.append((TYPES.get(wid, wid), s32(b, o + 4), s32(b, o + 36), kc))
        o += 88 + nk * ks
    if o != len(b):
        raise SystemExit("widget walk ended at %d, block is %d" % (o, len(b)))
    return n, out

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/lib/firmware/omap_aess-adfw.bin"
    want = sys.argv[2] if len(sys.argv) > 2 else "--all"
    b = blocks(path)

    if want in ("--all", "--routes"):
        r = routes(b[2][0])
        print("== %d DAPM routes ==" % len(r))
        for sink, ctl, src in r:
            print('   { "%s", %s, "%s" },'
                  % (sink, '"%s"' % ctl if ctl else "NULL", src))

    if want in ("--all", "--widgets"):
        n, w = widgets(b[3][0])
        print("\n== %d DAPM widgets, all decoded ==" % n)
        for typ, name, sname, kc in w:
            print("   %-9s %-24s stream=%-16s %s"
                  % (typ, name, sname or "-", kc if kc else ""))

main()
