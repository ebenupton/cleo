#!/bin/sh
# Apply the corpus, bisect the first behavioural failure, blacklist it, repeat.
#   tools/grind.sh [rounds]
# The blacklist accumulates in build/skip.txt.  Skipping one proposal changes which
# others are superseded, so the whole apply has to be redone each round rather than
# patched up -- which is also why the snapshots are rebuilt from scratch every time.
cd "$(dirname "$0")/.."
R=${1:-12}
touch build/skip.txt
i=0
while [ $i -lt $R ]; do
  i=$((i+1))
  S=$(tr '\n' ',' < build/skip.txt | sed 's/,$//')
  echo "=== round $i  skipping: ${S:-none}"
  python3 tools/apply_all.py --skip "$S" 2>&1 | tail -3
  ./build.sh >/dev/null 2>&1 || { echo "BUILD BROKEN"; exit 1; }
  if [ "$(tools/check.sh 160)" = ok ]; then
    echo "=== round $i: all checks clean with $(wc -l < build/skip.txt) skipped"
    exit 0
  fi
  tools/bisect.sh all - 160 > build/bisect.log 2>&1
  tail -3 build/bisect.log
  C=$(grep '^culprit:' build/bisect.log | awk '{print $2}')
  [ -z "$C" ] && { echo "bisect found nothing"; exit 1; }
  echo "$C" >> build/skip.txt
  echo "=== blacklisted $C"
done
