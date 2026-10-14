#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
NDK_VERSION="28.2.13676358"
CMAKE_VERSION="3.31.6"

NDK="$ANDROID_HOME/ndk/$NDK_VERSION"
CMAKE="$ANDROID_HOME/cmake/$CMAKE_VERSION/bin/cmake"
NINJA="$ANDROID_HOME/cmake/$CMAKE_VERSION/bin/ninja"

BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
JOBS="${JOBS:-2}"

if [ ! -d "$NDK" ]; then
    echo "ERRO: NDK $NDK_VERSION não encontrado em $ANDROID_HOME"
    exit 1
fi

if [ ! -x "$CMAKE" ]; then
    echo "ERRO: CMake não encontrado: $CMAKE"
    exit 1
fi

if [ ! -x "$NINJA" ]; then
    echo "ERRO: Ninja não encontrado: $NINJA"
    exit 1
fi

SDK_OUT="${THPS_SDK:-$(dirname "$REPO")/rexglue-sdk-android}/out/android-arm64"

if [ "${PROBE_ONLY:-0}" = "1" ]; then
    OUT="$REPO/android/native-build/probe"
    EXTRA=(-DTHPS_GEN_DIR=/nonexistent)
else
    OUT="$REPO/android/native-build/$BUILD_TYPE"
    EXTRA=()
fi

LIBS="$REPO/android/app/src/main/jniLibs/arm64-v8a"

find_first() {
    local pattern="$1"
    shift

    local root
    local found

    for root in "$@"; do
        [ -d "$root" ] || continue

        found="$(find "$root" -type f -name "$pattern" -print -quit 2>/dev/null || true)"

        if [ -n "$found" ]; then
            printf '%s\n' "$found"
            return 0
        fi
    done

    return 1
}

stage() {
    local pattern="$1"
    local file

    file="$(find_first "$pattern" "$OUT" "$SDK_OUT" || true)"

    if [ -z "$file" ]; then
        echo "ERRO: biblioteca não encontrada: $pattern"
        echo "Diretório de compilação: $OUT"
        echo "Diretório do SDK: $SDK_OUT"
        exit 1
    fi

    cp "$file" "$LIBS/"
    echo "Biblioteca copiada: $(basename "$file")"
}

echo "=== Configurando compilação Android ==="
echo "NDK: $NDK"
echo "Saída: $OUT"
echo "Probe somente: ${PROBE_ONLY:-0}"

"$CMAKE" \
    -S "$REPO/android/native" \
    -B "$OUT" \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-29 \
    -DANDROID_STL=c++_shared \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_C_FLAGS_RELWITHDEBINFO="${OPT_FLAGS:--O3 -mtune=cortex-a715 -g -DNDEBUG}" \
    -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="${OPT_FLAGS:--O3 -mtune=cortex-a715 -g -DNDEBUG}" \
    "${EXTRA[@]}"

echo "=== Compilando bibliotecas ==="

"$CMAKE" --build "$OUT" --parallel "$JOBS"

mkdir -p "$LIBS"

if [ "${PROBE_ONLY:-0}" = "1" ]; then
    echo "=== Preparando biblioteca de diagnóstico ==="
    stage "librb2probe.so"
else
    echo "=== Preparando bibliotecas do jogo ==="
    stage "libmain.so"
    stage "librexruntime*.so"
    stage "librexgpu-xenos*.so"

    for hook in \
        libmain_hook.so \
        libhook_impl.so \
        libfile_redirect_hook.so \
        libgsl_alloc_hook.so
    do
        if find_first "$hook" "$OUT" "$SDK_OUT" >/dev/null 2>&1; then
            stage "$hook"
        fi
    done
fi

CXX_SHARED="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"

if [ ! -f "$CXX_SHARED" ]; then
    echo "ERRO: libc++_shared.so não encontrada: $CXX_SHARED"
    exit 1
fi

cp "$CXX_SHARED" "$LIBS/"
echo "Biblioteca copiada: libc++_shared.so"

if [ "${STRIP:-0}" = "1" ]; then
    STRIP_TOOL="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"

    for file in "$LIBS"/*.so; do
        [ -f "$file" ] || continue
        "$STRIP_TOOL" --strip-unneeded "$file"
    done
fi

echo "[OK] Bibliotecas preparadas em: $LIBS"
