; Cleo's keys, for the engine's keyboard scan (kernel.s scan_keys, which
; includes this where it is placed: KEYN entries, each a key's internal number
; -- the keyboard matrix's, written to the VIA's port A -- and the K_ bit
; (defs.s) it sets in keys).  Two keys to a bit: Z and cursor left K_LEFT, X and
; cursor right K_RIGHT, : and cursor up K_UP, / and cursor down K_DOWN, RETURN
; and SPACE K_FIRE.  The logic reads keys (logic.s: K_UP|K_FIRE jumps, K_DOWN
; throws), the menus through menu_keys (menu.s).
KEYN = 10
key_tab:    .byte $61,$19, $42,$79, $48,$39,$49    ; Z, left;  X, right;  :, up, RETURN
            .byte $68,$29, $62                     ; /, down;  SPACE
key_bits:   .byte K_LEFT,K_LEFT, K_RIGHT,K_RIGHT, K_UP,K_UP,K_FIRE
            .byte K_DOWN,K_DOWN, K_FIRE
