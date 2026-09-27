; The Master's padding in the sprite banks: its 65C02 code is shorter than the Model
; B's, and the room it leaves (the pinned layout's: tools/pincfg.py) is spent before
; the hot blitters so that their branches cross no page boundary -- the Model B's are
; placed by the order of its code alone.  Found by the build (test/pagecheck.py over
; the profile's hot branches); each is at most the Master's slack in its bank.
PADM_FN4 = 26                       ; bank 4: before the unmirrored mask blitter
PADM_FM4 = 0                        ;         before the mirrored one
PADM_FN5 = 3                        ; bank 5: before the mask blitter
PADM_FC5 = 28                       ;         before the copy blitter
; Bank 7's engine code (ENGCODE) ends at the kernel on the Model B, so a pad there
; places the code before it; the Master's runs on from the Model B's start, so a pad
; places the code after it.  Each keeps copy_partial's and blank_below's loops in a page.
PADB_BB = 19                        ; the Model B: after blank_below
PADM_CP = 20                        ; the Master: before copy_partial
