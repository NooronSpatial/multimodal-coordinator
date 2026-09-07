#!/bin/sh
# THE SHAPE OF THE REPO, COUNTED BY THE MACHINE (ARCHITECTURE.md, AC-210).
#
# The "shape in numbers" paragraph was wrong four times, twice inside its
# own correction, because a human retyped it. This script is the number's
# only source now: run it, paste its output with the commit it names, and
# if the page and the script ever disagree, the script is right.
#
# The runner line takes ~100 s: it runs the suite, because the runner is
# the authority on how many tests exist, and counting `@Test` by hand is
# how the paragraph went wrong in the first place.
set -e
cd "$(dirname "$0")/.."
count() { find "$@" -name '*.swift' -print0 | xargs -0 cat | wc -l | tr -d ' '; }
printf 'commit          %s\n' "$(git rev-parse --short HEAD)"
printf 'library core    %s lines   Sources/MultiModalKit\n' "$(count Sources/MultiModalKit)"
printf 'all sources     %s lines   every product, demo and instrument under Sources/\n' "$(count Sources)"
printf 'demo app        %s lines   Demo/\n' "$(count Demo)"
printf 'tests           %s lines   Tests/\n' "$(count Tests)"
printf 'TurnCoordinator %s lines across %s files\n' \
  "$(cat Sources/MultiModalKit/Conversation/TurnCoordinator*.swift | wc -l | tr -d ' ')" \
  "$(ls Sources/MultiModalKit/Conversation/TurnCoordinator*.swift | wc -l | tr -d ' ')"
printf 'runner          %s\n' "$(swift test 2>&1 | grep -o 'Test run with [0-9]* tests in [0-9]* suites' | tail -1)"
