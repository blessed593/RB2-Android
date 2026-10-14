#!/usr/bin/env bash
# Build the host Linux x86_64 rexglue code-generation tool.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SDK="${1:-$(dirname "$REPO")/rexglue-sdk-android}"

if [ ! -f "$SDK/.android-patches/.applied" ]; then
  echo "SDK tree $SDK is not prepared: run tools/android/prepare_sdk.sh"
  exit 1
fi

# Require the intended compiler instead of silently using /usr/bin/clang++.
CC="${CC:-clang-20}"
CXX="${CXX:-clang++-20}"

command -v "$CC"
command -v "$CXX"

"$CC" --version
"$CXX" --version

cd "$SDK"

# Configure the preset with explicit compiler selections.
# CMake uses these on the first configuration of the build directory.
cmake --preset linux-amd64 \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX"

# Confirm which compiler CMake actually selected.
grep -E 'CMAKE_(C|CXX)_COMPILER:FILEPATH=' \
  out/build/linux-amd64/CMakeCache.txt || true

cmake --build --preset linux-amd64-release --target rexglue

test -x "$SDK/out/linux-amd64/Release/rexglue"

echo "[ok] $SDK/out/linux-amd64/Release/rexglue"
