#!/bin/zsh
# The 20x loop (the house rule): the whole suite twenty times, one summary line
# per run, and the full log of every run that does not pass. Kept in the repo:
# the scratch copy was removed by the system's cleanup (memory: scratchpad is
# not durable). Usage: docs/evidence/5d/loop20.sh <name>   (build the tests first)
cd "$(dirname "$0")/../../.."
NAME=${1:?a name for the evidence files}
OUT=docs/evidence/5d/stability-$NAME.txt
echo "# the 20x loop at $(git rev-parse --short HEAD) — $NAME. swift test --skip-build, this Mac, $(sysctl -n hw.ncpu) cores." > $OUT
for i in $(seq 1 20); do
  swift test --skip-build > /tmp/loop-run.log 2>&1
  line=$(grep -E "Test run with" /tmp/loop-run.log | tail -1)
  echo "run $i: $line" >> $OUT
  if ! echo "$line" | grep -q "passed after"; then cp /tmp/loop-run.log docs/evidence/5d/stability-$NAME-run$i-FAILED.log; fi
done
echo "done $(date +%H:%M:%S)" >> $OUT
