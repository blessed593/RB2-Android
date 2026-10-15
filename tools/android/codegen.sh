#!/usr/bin/env bash
# Generate the game's C++ for Android from default.xex.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

GAME_ROOT="$(cd "${1:?usage: codegen.sh <dir containing default.xex> [SDK_DIR]}" && pwd)"

# Priority: explicit second argument, THPS_SDK environment variable, default path.
SDK="${2:-${THPS_SDK:-$(dirname "$REPO")/rexglue-sdk-android}}"

CLI="$SDK/out/linux-amd64/Release/rexglue"
OUT="$REPO/android/codegen"

echo "=== Android code generation ==="
echo "Game directory: $GAME_ROOT"
echo "SDK directory:  $SDK"
echo "CLI executable: $CLI"
echo "Output:         $OUT"

if [ ! -f "$GAME_ROOT/default.xex" ]; then
  echo "::error::default.xex not found in $GAME_ROOT"
  exit 1
fi

if [ ! -f "$SDK/.android-patches/.applied" ]; then
  echo "::error::ReXGlue Android SDK is not prepared: $SDK"
  exit 1
fi

if [ ! -x "$CLI" ]; then
  echo "::error::Host code-generation tool not found: $CLI"
  echo "Run tools/android/build_host_cli.sh first."
  exit 1
fi

if [ ! -f "$REPO/config/rb2_manifest.toml" ]; then
  echo "::error::Manifest not found: $REPO/config/rb2_manifest.toml"
  exit 1
fi

mkdir -p "$OUT"

MANIFEST="$OUT/rb2_manifest.local.toml"

sed \
  -e "s#REPLACE_ME#$GAME_ROOT#g" \
  -e 's#^out_directory_path = ".*"#out_directory_path = "generated-android/default"#' \
  "$REPO/config/rb2_manifest.toml" > "$MANIFEST"

cd "$OUT"

LD_LIBRARY_PATH="$SDK/out/linux-amd64/Release/lib:${LD_LIBRARY_PATH:-}" \
  "$CLI" codegen rb2_manifest.local.toml

GENERATED_DIR="$OUT/generated-android/default"

if [ ! -d "$GENERATED_DIR" ]; then
  echo "::error::Generated code directory not found: $GENERATED_DIR"
  exit 1
fi

CPP_COUNT="$(find "$GENERATED_DIR" -maxdepth 1 -type f -name '*.cpp' | wc -l)"

if [ "$CPP_COUNT" -eq 0 ]; then
  echo "::error::No C++ files were generated."
  exit 1
fi

echo "Code generation completed successfully."
echo "Generated C++ files: $CPP_COUNT"
echo "Output directory: $GENERATED_DIR"
