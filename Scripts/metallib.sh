#!/usr/bin/env bash
# BUILD the MLX shader library. Never vendor it (D-062 F-3 = A).
#
# Why this script exists at all: SwiftPM does NOT build MLX's Metal
# kernels — mlx-swift excludes them from its own build, by vendor design
# (INSTRUMENTS §24). Xcode does. So `swift test` can run MLX only if a
# `default.metallib` is sitting in the working directory, which is the
# fifth and last place MLX's loader looks.
#
# And the failure mode is not a red test: with no metallib, MLX ABORTS
# THE PROCESS. That is why MLXRuntime checks for this file with
# Foundation before MLX is touched at all (AC-129).
#
# Usage:   Scripts/metallib.sh          # writes ./default.metallib
# Then:    swift test                   # the live MLX tests now RUN
# Without it, those tests SKIP honestly and everything else stays green.
set -euo pipefail
cd "$(dirname "$0")/.."

DD="${TMPDIR:-/tmp}/mmk-metallib"
echo "building the Cmlx shaders with Xcode (SwiftPM cannot)…"

# Both --skip flags are needed and neither is a shortcut:
#   -skipMacroValidation        MLXHuggingFaceMacros needs one-time approval
#   -skipPackagePluginValidation mlx-swift ships a CudaBuild plug-in
xcodebuild -scheme MultiModalKitMLX \
           -destination 'platform=macOS,arch=arm64' \
           -derivedDataPath "$DD" \
           -skipMacroValidation \
           -skipPackagePluginValidation \
           build >/dev/null

FOUND="$(find "$DD" -name default.metallib -print -quit)"
if [ -z "$FOUND" ]; then
  echo "FAILED: Xcode built, but produced no default.metallib." >&2
  echo "Without it the live MLX tests will SKIP (they will not fail)." >&2
  exit 1
fi

cp "$FOUND" ./default.metallib
echo "wrote ./default.metallib ($(du -h ./default.metallib | cut -f1)) from:"
echo "  $FOUND"
echo
echo "it is gitignored on purpose — built, never committed."
