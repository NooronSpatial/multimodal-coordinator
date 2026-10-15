#!/bin/zsh
# The 20x loop (the house rule): the whole suite twenty times, one summary line
# per run, and the full log of every run that does not pass. Kept in the repo:
# the scratch copy was removed by the system's cleanup (memory: scratchpad is
# not durable). Usage: docs/evidence/5d/loop20.sh <name> [--without-downloads]
# (build the tests first).
#
# --without-downloads skips the download family, red on this Mac (the daemon
# family, D-139), by name — the seven that fail here, and the bench hygiene
# suite that drives the same file server. CI runs them all on a clean machine.
cd "$(dirname "$0")/../../.."
NAME=${1:?a name for the evidence files}
SKIPS=()
WHAT="swift test --skip-build"
if [[ "$2" == "--without-downloads" ]]; then
  for s in MLXBackgroundInstallTests ModelDownloaderTests KokoroInstallTests WhisperInstallTests \
           NeuralVoiceInstallTests ModelDownloaderReentryTests ModelDownloaderStaleResumeTests \
           DownloadBenchHygieneTests; do
    SKIPS+=(--skip "$s")
  done
  WHAT="$WHAT ${SKIPS[*]}"
fi
OUT=docs/evidence/5d/stability-$NAME.txt
echo "# the 20x loop at $(git rev-parse --short HEAD) — $NAME. $WHAT, this Mac, $(sysctl -n hw.ncpu) cores." > $OUT
for i in $(seq 1 20); do
  swift test --skip-build "${SKIPS[@]}" > /tmp/loop-run.log 2>&1
  line=$(grep -E "Test run with" /tmp/loop-run.log | tail -1)
  echo "run $i: $line" >> $OUT
  if ! echo "$line" | grep -q "passed after"; then cp /tmp/loop-run.log docs/evidence/5d/stability-$NAME-run$i-FAILED.log; fi
done
echo "done $(date +%H:%M:%S)" >> $OUT
