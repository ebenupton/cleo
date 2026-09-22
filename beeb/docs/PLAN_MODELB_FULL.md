# Cleo on the Model B: the full game

*Built 22 Sep 2026; modelb/DESIGN.md describes what was built.  Two departures
from the plan below: the sprite prologue stayed in bank 5 (the menu overlay goes
over the tiles only, so bank 5's code serves both images and nothing needs to be
assembled twice), which leaves 172 tiles of room; and the disc holds 28 files,
LDPROG by the boot files rather than last.*

The one-level demo (modelb/, DESIGN.md) becomes the whole game: title, help, level
select, all sixteen levels loaded from disc between levels, win/lose, hi-score.  The
target stays a Model B with four 16K sideways RAM banks and no other RAM: 30K of
main RAM is display, 768 bytes are everything else, so every level's data is gathered
from disc into the banks by a loader that exists only while the palette is black.

## Where the bytes go

The demo packs one level to the byte in all four banks.  For the full game the
per-level state of the worst level (L4B: 233 tiles, 256x32 map) is about 2.5K over
64K even after the music leaves bank 7, so three things move and one gives:

1. **Bank 5 is the overlay bank.**  During a level it holds the tile blitter, the
   ring work, LV_PAGE0 and this level's tiles ("the level image", BANK5L + gathered
   tiles).  During the menus it holds the menu code, the title tune and the font
   ("the menu image", BANK5M).  Both start with the common tables at $8000.
2. **The sprite prologue and SPRMASK move to bank 7**, with the logic: the menu draws
   the title pieces through it, and it is 1K the level image can give to tiles.  The
   records, KEEP and the dirty lists stay in bank 5 with match/erase/mark_dirty.
3. **The title pack goes to bank 6 during the menus**, as on the Master: the row loop
   and the mask tables that draw it are there, and the map and sprites it lands on
   are regathered at the next level load anyway.
4. **The three big outdoor levels fold a few more tiles.**  With the prologue out,
   the level image has room for 195 tiles; L2B/L4B/L6B need 221/233/215.  The
   packer folds the cheapest pairs by convert.py's own damage metric (cells x flat
   pixels changed): the ~20-40 folds each cost 300-700 damage units against the
   3237 the set fold already spent, and touch tiles used in one to three cells.
   The alternative was giving up display rows on those levels.

Fixed code sits at the top of banks 4 and 6 so the data below it can be any size.
OBJN is the Master's 149 (three levels have more than 128 objects); MAXSPR/BINMAX
are the maxima over every level (24 / 18).

Bank 7 budget: +494 (OBJN), +250 (disc bootstrap), +1000 (prologue + SPRMASK),
-2178 (music data and tick) against 331 free: ~750 free.

## The disc

Own image (cleob.ssd), under 31 files and 200K:

    !BOOT, LOADER          the MOS-time loader: drive and controller detection, the
                           bank images, the bar, then the game
    BANKS                  the fixed bank pieces (4, 5 level, 5 menu, 6, 7) with a
                           piece table; the game reloads bank 5's images from it
    LDPROG                 the load-time program (below)
    SPR, SPRAND, BOX       the Master's sprite files, gathered per level
    TILESO, TILESI         the Master's tile sets, gathered per level
    TITLE                  the title pack, into bank 6 for the menus
    L0..L15                per level: header, objects, attr/altcls (NTILES entries),
                           tile list, sprite placement, RLE map

Sector numbers are baked into LDPROG by mkdfs (as the Master's files.inc).

## Loading

The game abandons the MOS, so it has its own disc driver, as the Master does.  The
Model B has an 8271 or a 1770: both raise NMI for data, so the driver is an NMI
transfer routine at $0D00 (display RAM during a level, free during a load) and a
polled command sequencer.  The LOADER decides which at boot from the DFS ROM's
version (0.x/1.x = 8271, 2.x = 1770) and passes the drive DFS had current.

A level load, palette black, interrupts off:

1. bank 7 copies the bootstrap (NMI stub + read-sectors) to $0D00 and reads LDPROG
   to $0E00; LDPROG runs in main RAM and pages banks freely
2. BANKS: bank 5's level image (code) if the menu image is in
3. TILESO/TILESI staged at $2000, the level's tiles copied into bank 5 by its tile
   list; build_tileaddr
4. SPR, SPRAND, BOX staged in turn; each image and mask copied to the bank and
   address the packer chose; the directory and SPRMASK built from a template
5. the level file: tables into bank 7, the map RLE-decoded into bank 6
6. back to bank 7: the game's load_level continues as on the Master

The menu image is loaded the same way when the title is entered (title_res says
whether bank 5/6 still hold it).

## Menus on this target

menu.s is assembled under MODELB: the ring addresses and clear_ring's bounds are
this target's, getglyph reads the font from the menu image, draw_piece names bank 6.
The pause menu is the one cut: during a level bank 5 holds no font, so pause is a
freeze (the pause key toggles, ESCAPE returns to the title) rather than a list.

## Verification

bdiff per level against the 21-row Master (the harness starts either side at any
level), bcheck2/bring2 ring checks, bwork2 frame costs, menu screenshots, the load
path under jsbeeb's B-DFS1.2 (8271) and B1770 models, and a boot from drive 1.
