# Peephole survey

The program cut into 16-instruction windows and put to a farm of agents, each asked for
a cheaper 65C02 encoding of the sequences in its batch.

    python3 tools/windows.py        cut src/*.s into build/windows/batch_NN.md
                                    (16 instructions, stride 8, never crossing a routine,
                                     ranked by measured cost from build/linecost.json)
    ...run the agents on each batch, brief in AGENT_BRIEF.md, output build/windows/out_NN.json
    python3 tools/proposals.py      merge into opt/proposals.json, ranked by
                                    saving x executions-per-frame
    python3 tools/tryproposal.py N  apply proposal N; --revert puts the source back

`proposals.json` is a list of CLAIMS, not results. Nothing in it has been verified.
The arithmetic in an agent's `argument` field is worth reading and worth nothing on its
own: this session has already seen three "obviously equivalent" rewrites that were not,
all of them flag bugs (`bit` setting Z from A AND operand; `ldx #n` clobbering a Z that
was about to be branched on; a carry propagation that looked redundant and was load
bearing for a value that reaches -1).

Verifying one means, at minimum:

    python3 tools/tryproposal.py <rank>
    ./build.sh
    node tools/statediff.mjs <ref.ssd> <ref.labels> build/cleo.ssd build/labels.txt <lv> 300
    node tools/pixdiff.mjs   <ref.ssd> <ref.labels> build/cleo.ssd build/labels.txt <lv> 300
    node tools/bench.mjs <lv> ... && node tools/benchcmp.mjs <before.json> <after.json>

statediff alone is not enough: it compares object state, and a wrong sprite frame or a
mis-drawn tile leaves that identical. pixdiff alone is not enough either, for anything
on a path the scripted run does not reach -- and HARNESS_ALLOW_DAMAGE=1 exists because
the default run holds Cleo invulnerable and never enters a knockback state at all.

## proposals.json / CATALOGUE.md

`tools/proposals.py` merges `build/windows/out_*.json` (the agent farm's replies) into
`opt/proposals.json` -- every field the agent returned, plus the window it answered, the
executions per frame from the profile, and the overlap set.  `opt/CATALOGUE.md` is the
readable index of the same data.

Ranking is in cycles per frame, not raw saving: a 250-cycle win in `calc_ring` is worth
less than a 2-cycle win inside `drawrect`'s row loop.  The weighting is capped at the
cycles the profile attributes to the window, because agents mixed units -- some costed a
whole loop as one execution.  Entries over that cap carry `overclaim`.

None of it is verified.  Apply one proposal at a time, gated on statediff + pixdiff.

## Screening the corpus

    python3 tools/screen.py             apply each alone: match, assemble, fit, no branch moved
    python3 tools/review.py > r.txt     each proposal as a diff plus the agent's reasoning
    python3 tools/apply_all.py          apply the survivors best-first onto the growing tree
    tools/grind.sh                      ...then test, bisect the first failure, blacklist, repeat
    tools/verify.sh full                8 levels x 300 frames, pixels, and the damage runs
    node tools/titlediff.mjs A B        the attract loop, which no in-level test reaches
    node tools/titlephase.mjs A B       ...and whether a difference there is phase or a bug
    python3 tools/linecost.py f.s:a-b   what a line actually costs, per frame

Read the proposals.  The screen answers three decidable questions and the tests answer
what they can reach; neither reads a comment.  logic_1353 turned `pha` into `tax` and
wrote the matching `pla` -> `txa` as a comment instead of as code.
