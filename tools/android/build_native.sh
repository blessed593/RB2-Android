#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/android-sdk}}"
NDK_VERSION="28.2.13676358"
CMAKE_VERSION="3.31.6"

NDK="$ANDROID_HOME/ndk/$NDK_VERSION"
CMAKE="$ANDROID_HOME/cmake/$CMAKE_VERSION/bin/cmake"
NINJA="$ANDROID_HOME/cmake/$CMAKE_VERSION/bin/ninja"

# Use o SDK informado pelo workflow.
SDK="${THPS_SDK:-$(dirname "$REPO")/rexglue-sdk-android}"
SDK_OUT="$SDK/out/android-arm64"

BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
JOBS="${JOBS:-4}"

# Verifica as ferramentas do Android.
if [ ! -d "$NDK" ]; then
    echo "::error::Android NDK $NDK_VERSION não encontrado: $NDK"
    exit 1
fi

if [ ! -x "$CMAKE" ]; then
    echo "::error::CMake não encontrado: $CMAKE"
    exit 1
fi

if [ ! -x "$NINJA" ]; then
    echo "::error::Ninja não encontrado: $NINJA"
    exit 1
fi

# Verifica o SDK ReXGlue.
if [ ! -f "$SDK/.android-patches/.applied" ]; then
    echo "::error::SDK ReXGlue não preparado: $SDK"
    exit 1
fi

if [ ! -f "$SDK/CMakeLists.txt" ]; then
    echo "::error::CMakeLists.txt não encontrado no SDK: $SDK"
    exit 1
fi

# Configura o tipo de compilação.
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

        found="$(
            find "$root" -type f -name "$pattern" -print -quit 2>/dev/null || true
        )"

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
        echo "::error::Biblioteca não encontrada: $pattern"
        echo "Diretório de compilação: $OUT"
        echo "Diretório do SDK: $SDK_OUT"
        exit 1
    fi

    cp "$file" "$LIBS/"
    echo "Biblioteca copiada: $(basename "$file")"
}

echo "=== Configurando compilação Android ==="
echo "Repositório: $REPO"
echo "SDK ReXGlue: $SDK"
echo "NDK: $NDK"
echo "CMake: $CMAKE"
echo "Saída: $OUT"
echo "Tipo de compilação: $BUILD_TYPE"
echo "Paralelismo: $JOBS"
echo "Probe somente: ${PROBE_ONLY:-0}"

# IMPORTANTE:
# THPS_SDK aponta explicitamente para o SDK preparado pelo workflow.
"$CMAKE" \
    -S "$REPO/android/native" \
    -B "$OUT" \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DTHPS_SDK="$SDK" \
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

# Copia a biblioteca padrão do C++ exigida pelo Android.
CXX_SHARED="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"

if [ ! -f "$CXX_SHARED" ]; then
    echo "::error::libc++_shared.so não encontrada: $CXX_SHARED"
    exit 1
fi

cp "$CXX_SHARED" "$LIBS/"
echo "Biblioteca copiada: libc++_shared.so"

# Remove símbolos de depuração somente se solicitado.
if [ "${STRIP:-0}" = "1" ]; then
    STRIP_TOOL="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"

    if [ ! -x "$STRIP_TOOL" ]; then
        echo "::error::llvm-strip não encontrado: $STRIP_TOOL"
        exit 1
    fi

    for file in "$LIBS"/*.so; do
        [ -f "$file" ] || continue
        "$STRIP_TOOL" --strip-unneeded "$file"
    done
fi

echo "=== Bibliotecas preparadas ==="
find "$LIBS" -maxdepth 1 -type f -name '*.so' -printf '%f\n' | sort

echo "[OK] Bibliotecas preparadas em: $LIBS"
