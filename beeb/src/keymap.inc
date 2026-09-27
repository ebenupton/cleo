; Cleo's keys, for beebgame's keyboard scan (engine.s scan_keys): each key's internal
; key number (the keyboard matrix's) and the K_ bit it sets -- Z and cursor left
; K_LEFT, X and cursor right K_RIGHT, : and cursor up K_UP, RETURN and SPACE K_FIRE,
; / and cursor down K_DOWN (logic.s reads them)
KEYN = 10
keytab:  .byte $61,$19, $42,$79, $48,$39,$49, $68,$29, $62
keybits: .byte K_LEFT,K_LEFT, K_RIGHT,K_RIGHT, K_UP,K_UP,K_FIRE, K_DOWN,K_DOWN, K_FIRE
