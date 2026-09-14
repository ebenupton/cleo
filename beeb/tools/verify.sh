#!/bin/sh
# Verify the working tree against build/base, in parallel across levels.
#   tools/verify.sh quick   L0+L5 state, L0 pixels, 150 frames   (~30s, batch triage)
#   tools/verify.sh full    all 8 levels state, 4 levels pixels, 300 frames + damage run
# Prints one line per check; any line containing DIVERGES or "differs" is a failure.
cd "$(dirname "$0")/.."
B="build/base/cleo.ssd build/base/labels.txt build/cleo.ssd build/labels.txt"
mode=${1:-quick}
if [ "$mode" = quick ]; then SL="0 5"; PL="0"; N=150; else SL="0 1 2 3 4 5 6 7"; PL="0 3 5 6"; N=300; fi
for l in $SL; do node tools/statediff.mjs $B $l $N 2>&1 | grep -v Running & done
for l in $PL; do node tools/pixdiff.mjs   $B $l $N 2>&1 | grep -v Running & done
if [ "$mode" = full ]; then
  # the default run holds Cleo invulnerable, so knockback -- the one path with 16-bit
  # object state on it -- is never entered unless this is set
  for l in 0 5; do HARNESS_ALLOW_DAMAGE=1 node tools/statediff.mjs $B $l $N 2>&1 \
      | grep -v Running | sed 's/^/DMG /' & done
fi
wait
