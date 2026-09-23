# A headless BeebEm, for lock-step against jsbeeb

BeebEm is Windows-only, but its emulation core is plain C++: this directory builds
just that core on macOS (or Linux) with a stub front end, and a harness that drives
the Model B disc exactly as `tools/bopen.mjs` drives jsbeeb -- SHIFT-BREAK, the title
skipped, `scan_keys` stubbed, the same key script -- and prints the game's state at
every `frame_top`: the zero-page logic, the object arrays, a hash of the display RAM,
the CRTC registers.  `tools/bdump.mjs` prints the same line from jsbeeb, and
`cmpdump.py` finds the first frame that differs.

At chosen frames (`--shot F`, `--shotevery K`) both sides also save, at the game's
next vsync so they show the same field: the picture (BeebEm's line buffer as a PPM,
jsbeeb's canvas as a PNG), the display RAM, and on BeebEm's side the game's section
table (SECTAB, the palette) and a log of every CRTC frame restart -- with the scanlines
it lasted -- and every CRTC register write, with the row and scanline BeebEm believed
it was on.  `cmpshots.py` reduces both pictures to a grid of BBC colours and reports
the mismatching cells by row.

## Build and run

    tools/hbeebem/build.sh              # clones stardot/beebem-windows, builds build/hbeebem

then from `modelb/`, with a disc built:

    tools/hbeebem/build/hbeebem --userdata tools/hbeebem/build/userdata --disc build/cleob.ssd \
        --labels build/labels.txt --frames 240 --seed 3 --level 1 --shotevery 20 --out /tmp/hb > /tmp/hb.txt
    node tools/bdump.mjs 240 3 1 -1 /tmp/jb 20 > /tmp/jb.txt
    python3 tools/hbeebem/cmpdump.py /tmp/hb.txt /tmp/jb.txt
    for f in 0 20 40; do python3 tools/hbeebem/cmpshots.py /tmp/hb_f$f.ppm /tmp/jb_f$f.png; done

The ROMs come from the BeebEm release zip (fetched by the script), whose default Model
B has sideways RAM in banks 4-7, so the game runs in banks 4-7 there; `bopen.mjs` maps
jsbeeb's to its sockets.  `DebugEnabled` is set true in `stubs.cpp` so that
`Exec6502Instruction` runs one instruction per call (the harness's breakpoints need
that); the debugger itself is stubbed out.

## What it found (23-24 Sep 2026)

With the disc as committed (R8 = 0), BeebEm's picture is identical to jsbeeb's, cell
for cell, in 47 of 48 samples over four levels; the 48th differs in the sprites and
one redrawn band only -- the two emulators flipped buffers one field apart -- and the
logic state and CRTC registers agree at every one of 960 frames.  With the disc from
before the R8 fix, BeebEm's sections come out the wrong length (81 scanlines for 80, 4
for 2: its interlace-frame stretch), its chain is out of phase from the second frame,
and 10 of 24 pictures differ wholesale.  So a BeebEm that still glitches is running a
disc without that fix, or a BeebEm whose settings differ from the defaults built here.
