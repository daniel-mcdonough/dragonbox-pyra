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

WIDGETS (block type 3) are decoded as far as their identity:

    u32 count, then count * { u32 id; char name[32]; char sname[32];
                              u32 reg, shift, x, y, num_kcontrols;
                              <num_kcontrols embedded kcontrols> }

count is 46. The base element is 88 bytes and the first 18 -- all AIF widgets
with no kcontrols -- walk exactly. The `id` is a snd_soc_dapm_type from before
regulator_supply was added to that enum, which shifts everything after
snd_soc_dapm_supply down by one:

    2 = mux        21 = aif_in        22 = aif_out        5 = mixer

That reading is what makes every widget make sense -- MM_DL and TONES_DL are
aif_in, PDM_DL1 and MM_UL1 are aif_out, MUX_UL00 is a mux -- and it is the
part that would be easiest to get quietly wrong, so it is worth restating that
it is inferred from consistency across 19 widgets, not read from the file.

WHAT IS NOT DECODED: the embedded kcontrols, and therefore the widget walk
past the first 18. They begin with a name[32] and no leading size word, so
their length depends on their type -- a mux's enum kcontrol carries its item
texts inline (15 * 32 bytes for MUX_UL00's "Route"), a mixer's does not. Until
that is decoded the widget list cannot be walked to the end.

It may not need to be. The routes already name every widget that matters and,
in their `control` field, every mixer kcontrol name; a mixer's kcontrols can be
derived as the distinct controls of the routes that sink into it. That would
mean emitting the graph as static tables from recovered names -- the same shape
0015 took for the controls -- with only the widget types inferred.
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

TYPES = {2: "mux", 5: "mixer", 21: "aif_in", 22: "aif_out"}

def widgets(b):
    n = struct.unpack_from("<I", b, 0)[0]
    out, o = [], 4
    while o + 88 <= len(b) and len(out) < n:
        wid = struct.unpack_from("<I", b, o)[0]
        if wid not in TYPES:
            break                      # an embedded kcontrol we cannot size
        nk = struct.unpack_from("<I", b, o + 84)[0]
        out.append((wid, s32(b, o + 4), s32(b, o + 36), nk))
        if nk:
            break                      # see the module docstring
        o += 88
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
        print("\n== %d DAPM widgets declared, %d decoded ==" % (n, len(w)))
        for wid, name, sname, nk in w:
            print("   %-8s %-22s stream=%-16s kcontrols=%d"
                  % (TYPES.get(wid, wid), name, sname or "-", nk))
        if len(w) < n:
            print("   ... stopped: the next widget embeds kcontrols, which are")
            print("       not sized yet. See the docstring.")

main()
