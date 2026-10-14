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

# Use the intended compiler unless the workflow explicitly overrides it.
CC="${CC:-clang-20}"
CXX="${CXX:-clang++-20}"

echo "=== Checking host compilers ==="
command -v "$CC"
command -v "$CXX"

"$CC" --version
"$CXX" --version

cd "$SDK"

# Remove the previous host build directory so CMake cannot reuse
# a compiler selected during an earlier configuration.
echo "=== Cleaning previous host build configuration ==="
rm -rf out/build/linux-amd64
rm -rf out/linux-amd64

# Configure the Linux x86_64 preset with explicit compiler paths.
echo "=== Configuring CMake with the requested compilers ==="
cmake --preset linux-amd64 \
  -DCMAKE_C_COMPILER="$(command -v "$CC")" \
  -DCMAKE_CXX_COMPILER="$(command -v "$CXX")"

# Display the compiler selection recorded by CMake.
echo "=== CMake compiler configuration ==="
grep -E '^CMAKE_(C|CXX)_COMPILER(:FILEPATH|:STRING)?=' \
  out/build/linux-amd64/CMakeCache.txt || true

# Ensure the configuration did not silently select the old compiler.
if ! grep -Fq "$(command -v "$CXX")" \
  out/build/linux-amd64/CMakeCache.txt; then
  echo "::error::CMake did not record the expected C++ compiler: $CXX"
  exit 1
fi

# Compile the host-side recompiler.
echo "=== Building rexglue ==="
cmake --build --preset linux-amd64-release --target rexglue

# Confirm the expected executable exists.
REXGLUE="$SDK/out/linux-amd64/Release/rexglue"

if [ ! -x "$REXGLUE" ]; then
  echo "::error::The rexglue executable was not created at $REXGLUE"
  exit 1
fi

echo "=== Host tool build completed successfully ==="
ls -lh "$REXGLUE"
echo "[ok] $REXGLUE"
