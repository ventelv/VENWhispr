#!/bin/bash
# Builds whisper-server and llama-server from pinned, verified sources as self-contained executables
# (statically linked, Metal shaders embedded, Apple Silicon, macOS 14+) into vendor/bin.
# build.sh bundles them inside VENWhispr.app, so people who download the app don't need Homebrew.
# Needs: Xcode Command Line Tools and cmake (brew install cmake). Usage: scripts/build_servers.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WHISPER_TAG=v1.9.5
WHISPER_COMMIT=d1be6fde11ac6e0407606b4e42fe72d34add8037
LLAMA_TAG=v0.6.0
LLAMA_COMMIT=d81235049384534c167caea52b85a694f6103d14

SRC=vendor/src
OUT=vendor/bin
JOBS="$(sysctl -n hw.ncpu)"

command -v cmake >/dev/null || { echo "cmake is missing: brew install cmake" >&2; exit 1; }

# Sources are fetched by tag, then checked against the commit we tested, since tags can be moved.
fetch() {
    local name="$1" url="$2" tag="$3" commit="$4"
    local dir="$SRC/$name"
    if [ ! -d "$dir/.git" ] || [ "$(git -C "$dir" rev-parse HEAD)" != "$commit" ]; then
        rm -rf "$dir"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$url" "$dir"
    fi
    local got
    got="$(git -C "$dir" rev-parse HEAD)"
    [ "$got" = "$commit" ] || { echo "$name $tag is commit $got, expected $commit. Refusing to build." >&2; exit 1; }
}

# Every Apple Silicon chip supports what the M1 does, so target that rather than this Mac's CPU.
COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_NATIVE=OFF
    -DGGML_CPU_ARM_ARCH=armv8.5-a+fp16
    -DGGML_OPENMP=OFF
)

build() {
    local name="$1" target="$2"; shift 2
    echo "==> Building $target"
    cmake -S "$SRC/$name" -B "$SRC/$name/build" "${COMMON[@]}" "$@" >/dev/null
    cmake --build "$SRC/$name/build" --config Release --target "$target" -j "$JOBS" >/dev/null
    mkdir -p "$OUT"
    cp "$SRC/$name/build/bin/$target" "$OUT/$target"
    strip -x "$OUT/$target"
}

# Fails if a binary needs anything outside macOS itself, or a newer macOS than 14.
check() {
    local bin="$OUT/$1"
    local extra
    extra="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -v -E '^/usr/lib/|^/System/Library/' || true)"
    [ -z "$extra" ] || { echo "$1 links libraries outside macOS: $extra" >&2; exit 1; }
    local minos
    minos="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/ {f=1} f && /minos/ {print $2; exit}')"
    [ "$minos" = "14.0" ] || { echo "$1 needs macOS $minos, expected 14.0" >&2; exit 1; }
    echo "$1: $(du -h "$bin" | cut -f1 | tr -d ' '), macOS $minos+, no external libraries"
}

fetch whisper.cpp https://github.com/ggml-org/whisper.cpp.git "$WHISPER_TAG" "$WHISPER_COMMIT"
fetch llama.cpp https://github.com/ggml-org/llama.cpp.git "$LLAMA_TAG" "$LLAMA_COMMIT"

build whisper.cpp whisper-server -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF
build llama.cpp llama-server -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_SERVER=ON -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF

check whisper-server
check llama-server
