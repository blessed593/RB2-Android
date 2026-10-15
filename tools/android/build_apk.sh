#!/usr/bin/env bash
# Package staged native libraries into an Android APK.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/android-sdk}}"
SDK_TREE="${THPS_SDK:-$(dirname "$REPO")/rexglue-sdk-android}"
ANDROID_PROJECT="$REPO/android"

# Verify Android SDK.
if [ ! -d "$ANDROID_HOME" ]; then
  echo "ERROR: Android SDK directory not found: $ANDROID_HOME"
  exit 1
fi

# Verify prepared ReXGlue SDK.
if [ ! -f "$SDK_TREE/CMakeLists.txt" ]; then
  echo "ERROR: ReXGlue SDK CMakeLists.txt not found: $SDK_TREE"
  exit 1
fi

if [ ! -f "$SDK_TREE/.android-patches/.applied" ]; then
  echo "ERROR: ReXGlue SDK patches are not prepared."
  echo "Run tools/android/prepare_sdk.sh first."
  exit 1
fi

# Verify SDL3 Gradle Wrapper source.
SDL_PROJECT="$SDK_TREE/thirdparty/sdl3/android-project"

for file in \
  "$SDL_PROJECT/gradlew" \
  "$SDL_PROJECT/gradle/wrapper/gradle-wrapper.jar" \
  "$SDL_PROJECT/gradle/wrapper/gradle-wrapper.properties"
do
  if [ ! -f "$file" ]; then
    echo "ERROR: Required SDL3 Gradle Wrapper file not found: $file"
    exit 1
  fi
done

cd "$ANDROID_PROJECT"

# Copy the Gradle Wrapper only if it is incomplete.
if [ ! -f gradlew ] \
  || [ ! -f gradle/wrapper/gradle-wrapper.jar ] \
  || [ ! -f gradle/wrapper/gradle-wrapper.properties ]; then

  echo "Preparing Gradle Wrapper from SDL3..."
  cp "$SDL_PROJECT/gradlew" gradlew
  chmod +x gradlew

  mkdir -p gradle/wrapper
  cp "$SDL_PROJECT/gradle/wrapper/gradle-wrapper.jar" \
     "$SDL_PROJECT/gradle/wrapper/gradle-wrapper.properties" \
     gradle/wrapper/
fi

# Configure the Android SDK path for Gradle.
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > local.properties

# Ensure native libraries were staged by build_native.sh.
LIB_DIR="app/src/main/jniLibs/arm64-v8a"

if [ ! -d "$LIB_DIR" ] || ! compgen -G "$LIB_DIR/*.so" >/dev/null; then
  echo "ERROR: No native libraries found in $LIB_DIR"
  echo "Run tools/android/build_native.sh first."
  exit 1
fi

echo "Android SDK: $ANDROID_HOME"
echo "ReXGlue SDK: $SDK_TREE"
echo "Native libraries:"
find "$LIB_DIR" -maxdepth 1 -type f -name '*.so' -printf '  %f (%s bytes)\n' | sort

# Build the release APK.
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/temurin-17-jdk-amd64}"
export PATH="$JAVA_HOME/bin:$PATH"

if ! command -v java >/dev/null 2>&1; then
  echo "ERROR: Java was not found. Check JAVA_HOME."
  exit 1
fi

java -version

./gradlew --no-daemon \
  -Prb2.sdk="$SDK_TREE" \
  assembleRelease \
  "$@"

APK="app/build/outputs/apk/release/app-release.apk"

if [ ! -s "$APK" ]; then
  echo "ERROR: APK was not generated or is empty: $APK"
  exit 1
fi

echo
echo "APK successfully generated:"
ls -lh "$APK"
