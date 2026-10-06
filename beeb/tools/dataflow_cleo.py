# dataflow_cleo.py -- Cleo's config for beebgame's dataflow tools (beebgame/tools/dataflow,
# gamecfg.py documents every key):
#   python3 beebgame/tools/dataflow/annotate.py --config tools/dataflow_cleo.py [--build build/modelb]
#
# The objects: OBJ_MAX records, one array a field (logic.s O_STAMP..O_EH, from LV_OBJST),
# the current one the index register equal to obj (process_object's Y; `ldy obj` after
# anything that changes it).  process_object dispatches on O_TYPE (jmp (jv) on the Model B,
# jmp (@tab,x) on the Master), so each handler sees its own type's fields.  level_init
# builds the records itself: its `sta otype` binds the type of the record being built.
# The game's stores through pointers the analysis cannot bound, none of them into the
# records ($8400 on): the bar's digits (logic.s, ptr), the menus' glyphs and pieces (sp),
# clear_ring (w16, the screen) and the pieces' unpack into TBUF (tp)
SCREEN_POINTERS = ('ptr', 'sp', 'w16', 'tp')

OBJECTS = dict(
    layout='soa',
    records='O_STAMP',
    count='OBJ_MAX',
    stride=16,
    type_field='O_TYPE',
    fields=('O_STAMP', 'O_TYPE', 'O_XL', 'O_XH', 'O_YL', 'O_YH', 'O_AL', 'O_AH', 'O_BL', 'O_BH',
            'O_CL', 'O_CH', 'O_DL', 'O_DH', 'O_EL', 'O_EH'),
    types=tuple(range(13)),
    type_prefix='OT_',
    current='obj',
    type_var='otype',
    game_bind=('src/logic.s', r'sta\s+otype\b', 'level_init'),
)
