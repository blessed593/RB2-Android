#!/usr/bin/env bash
# Build the ReXGlue SDK tree used for the Android port.
#
# ReXGlue v0.10.0
# + pinned third-party Android patches
# + project patches in filename order
#
# Supports GitHub Actions caching by accepting SDK_DIR as an argument.
# Existing SDK trees are reused, and unapplied patches are applied incrementally.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

SDK="${1:-$(dirname "$REPO")/rexglue-sdk-android}"
SDK_URL="https://github.com/rexglue/rexglue-sdk.git"
SDK_TAG="v0.10.0"

REF="0a79f938ab839c187d25bd7bf48e51e30a6150be"
BASE_URL="https://raw.githubusercontent.com/deivid22srk/hells-gate-recomp-android/$REF/patches/sdk"

ANDROID_PATCH="rexglue-sdk-v0.10.0-android.patch"
ANDROID_SHA="271ac5f0e4dece893fd3f18f93cfc96037987916def3545b1d6b253ab2dbf06b"

PERF_PATCH="rexglue-sdk-v0.10.0-android-perf.patch"
PERF_SHA="b85196c30136d1d24b1848af0bccd3b558392742cc11d391348666d76a6d0f10"

OURS_DIR="$REPO/patches/rexglue-sdk-android"
MARK="$SDK/.android-patches/.applied"
SHADER_HEADER="$SDK/src/graphics/vulkan/direct_resolve_shaders.h"

echo "== ReXGlue SDK directory: $SDK"

# Create the parent directory before cloning.
mkdir -p "$(dirname "$SDK")"

# Clone only when the SDK does not already exist.
if [ ! -f "$SDK/CMakeLists.txt" ]; then
  if [ -e "$SDK" ] && [ -n "$(ls -A "$SDK" 2>/dev/null || true)" ]; then
    echo "ERROR: SDK directory exists but is not a valid ReXGlue tree: $SDK"
    exit 1
  fi

  echo "== cloning $SDK_TAG with submodules"

  git clone \
    --branch "$SDK_TAG" \
    --recurse-submodules \
    --shallow-submodules \
    --jobs 8 \
    "$SDK_URL" \
    "$SDK"
fi

cd "$SDK"

# Ensure this is a Git working tree.
git rev-parse --is-inside-work-tree >/dev/null

git config user.name "${GIT_AUTHOR_NAME:-android-port}"
git config user.email "${GIT_AUTHOR_EMAIL:-android-port@localhost}"

mkdir -p .android-patches
touch "$MARK"

applied() {
  grep -qxF "$1" "$MARK"
}

# Download and validate the pinned third-party Android patches.
fetch_patch() {
  local name="$1"
  local expected_sha="$2"
  local file=".android-patches/$name"
  local tmp="/tmp/$name"

  if [ ! -f "$file" ]; then
    echo "== downloading $name"
    curl -fsSL --retry 3 --retry-delay 2 -o "$file" "$BASE_URL/$name"
  fi

  echo "$expected_sha  $file" | sha256sum -c - >/dev/null || {
    echo "ERROR: SHA-256 mismatch for $name"
    exit 1
  }

  tr -d '\r' < "$file" > "$tmp"
}

# Apply the third-party base exactly once.
if ! applied base; then
  echo "== checking base SDK version"

  actual_tag="$(git describe --tags --exact-match 2>/dev/null || true)"

  if [ "$actual_tag" != "$SDK_TAG" ]; then
    echo "ERROR: Expected SDK tag $SDK_TAG, found '${actual_tag:-unknown}'."
    exit 1
  fi

  if ! git diff --quiet -- . ':!thirdparty'; then
    echo "ERROR: SDK has uncommitted source changes; refusing to apply base patches."
    exit 1
  fi

  fetch_patch "$ANDROID_PATCH" "$ANDROID_SHA"
  fetch_patch "$PERF_PATCH" "$PERF_SHA"

  echo "== applying third-party Android base"

  git apply --whitespace=nowarn --index "/tmp/$ANDROID_PATCH"

  git apply \
    --whitespace=nowarn \
    --index \
    --exclude=src/system/mmio_handler.cpp \
    "/tmp/$PERF_PATCH"

  git commit -qm "base: $SDK_TAG + third-party Android patches ($REF)"

  echo base >> "$MARK"
else
  echo "== third-party Android base already applied"
fi

# Apply project patches in filename order.
shopt -s nullglob
patches=("$OURS_DIR"/*.patch)
shopt -u nullglob

if [ "${#patches[@]}" -eq 0 ]; then
  echo "ERROR: No project patches found in $OURS_DIR"
  exit 1
fi

for patch in "${patches[@]}"; do
  name="$(basename "$patch")"

  if applied "$name"; then
    echo "== already applied: $name"
    continue
  fi

  echo "== applying $name"

  git apply --whitespace=nowarn --unidiff-zero --index "$patch"
  git commit -qm "$name"

  echo "$name" >> "$MARK"
done

# Generate the fused resolve shaders when missing or when any shader source is newer.
if [ ! -f "$SHADER_HEADER" ] ||
   find "$REPO/tools/android/resolve_shaders" -type f \
     -newer "$SHADER_HEADER" -print -quit | grep -q .; then

  echo "== generating fused resolve shaders"

  SDK="$SDK" bash \
    "$REPO/tools/android/resolve_shaders/build.sh" \
    "$SHADER_HEADER"
else
  echo "== resolve shader header is up to date"
fi

echo "[ok] SDK ready: $SDK ($(grep -c . "$MARK") entries applied)"
