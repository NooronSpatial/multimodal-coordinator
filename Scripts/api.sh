#!/bin/sh
# The PUBLIC surface of the library, listed from the source — never typed
# into a document by hand (the shape.sh rule, D-054/5: a number or a name a
# human maintains in prose drifts). Run it; if docs/INTEGRATE.md's appendix
# disagrees with this output, the appendix is stale and this script is right.
#
# What it prints: one line per `public` declaration in the four library
# modules, grouped by module and file, with a multi-line signature folded
# onto one line. Doc comments and bodies are left out; the exact words are in
# the source, one grep away. Demos, instruments and tests are not the API.
set -e
cd "$(dirname "$0")/.."
echo "commit   $(git rev-parse --short HEAD)"
for module in MultiModalKit MultiModalKitMLX MultiModalKitTTS MultiModalKitWhisper MultiModalKitTesting; do
  echo
  echo "## $module"
  find "Sources/$module" -name '*.swift' | LC_ALL=C sort | while read -r file; do
    # A declaration starts a line with `public`/`open` (any indentation) and
    # ends at the first `{`, `=` or the end of a line that closes its `)`.
    awk -v file="${file#Sources/$module/}" '
      function flush() { if (sig != "") { gsub(/[ \t]+/, " ", sig); sub(/ *\{.*$/, "", sig); sub(/^ /, "", sig); print "  " file ": " sig; sig = "" } }
      function done_line(line) { return (open <= 0 && line !~ /,[ \t]*$/) || line ~ /\{/ }
      /^[ \t]*(public|open) / { flush(); sig = $0; open = gsub(/\(/, "(", $0) - gsub(/\)/, ")", $0); if (done_line($0)) { flush() } next }
      sig != "" { sig = sig " " $0; open += gsub(/\(/, "(", $0) - gsub(/\)/, ")", $0); if (done_line($0)) { flush() } }
    ' "$file"
  done
done
