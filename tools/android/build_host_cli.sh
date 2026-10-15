#!/usr/bin/env bash
# Build the host Linux x86_64 rexglue code-generation tool.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# Use the SDK path supplied by the workflow, if available.
SDK="${THPS_SDK:-${1:-$(dirname "$REPO")/rexglue-sdk-android}}"

echo "=== Checking ReXGlue SDK ==="
echo "Repository: $REPO"
echo "SDK path:   $SDK"

if [ ! -f "$SDK/.android-patches/.applied" ]; then
  echo "::error::SDK tree is not prepared: $SDK"
  echo "Run tools/android/prepare_sdk.sh first."
  exit 1
fi

if [ ! -f "$SDK/CMakeLists.txt" ]; then
  echo "::error::CMakeLists.txt not found in SDK: $SDK"
  exit 1
fi

# Use the intended compiler unless explicitly overridden.
CC="${CC:-clang-20}"
CXX="${CXX:-clang++-20}"

echo "=== Checking host compilers ==="
command -v "$CC"
command -v "$CXX"

"$CC" --version
"$CXX" --version

cd "$SDK"

# Remove previous host build directories.
echo "=== Cleaning previous host build configuration ==="
rm -rf out/build/linux-amd64
rm -rf out/linux-amd64

# Configure the Linux x86_64 preset.
echo "=== Configuring CMake with the requested compilers ==="
cmake --preset linux-amd64 \
  -DCMAKE_C_COMPILER="$(command -v "$CC")" \
  -DCMAKE_CXX_COMPILER="$(command -v "$CXX")"

# Verify compiler selection.
echo "=== CMake compiler configuration ==="
grep -E '^CMAKE_(C|CXX)_COMPILER(:FILEPATH|:STRING)?=' \
  out/build/linux-amd64/CMakeCache.txt || true

if ! grep -Fq "$(command -v "$CXX")" \
  out/build/linux-amd64/CMakeCache.txt; then
  echo "::error::CMake did not record the expected C++ compiler: $CXX"
  exit 1
fi

# Build the host-side recompiler.
echo "=== Building rexglue ==="
cmake --build --preset linux-amd64-release \
  --target rexglue \
  --parallel "${JOBS:-4}"

# Verify executable.
REXGLUE="$SDK/out/linux-amd64/Release/rexglue"

if [ ! -x "$REXGLUE" ]; then
  echo "::error::The rexglue executable was not created at $REXGLUE"
  echo "Searching for the generated executable..."
  find "$SDK/out" -type f -name rexglue -print 2>/dev/null || true
  exit 1
fi

echo "=== Host tool build completed successfully ==="
ls -lh "$REXGLUE"
echo "[ok] $REXGLUE"
