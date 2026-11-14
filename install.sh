#!/bin/bash
# Sets up VENWhispr on this Mac: checks the system, installs the local speech and punctuation
# servers with Homebrew, downloads the models, then builds and opens the app.
# Usage: ./install.sh
# Safe to run again. Finished steps are skipped and interrupted downloads resume.
set -euo pipefail
cd "$(dirname "$0")"

SUPPORT="$HOME/Library/Application Support/VENWhispr"
BREW=/opt/homebrew/bin/brew
HF=https://huggingface.co
DOWNLOAD_ATTEMPTS=5
# Room for the Homebrew packages and the build, on top of the models.
SPARE_BYTES=2000000000

# Each entry: file under $SUPPORT | download URL | size in bytes | SHA-256
MODELS=(
    "ggml-large-v3-turbo.bin|$HF/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin|1624555275|1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    "preview/ggml-base.bin|$HF/ggerganov/whisper.cpp/resolve/main/ggml-base.bin|147951465|60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
    "gemma-3-4b-it-Q4_K_M.gguf|$HF/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf|2489757856|882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863"
)

step() { printf '\n==> %s\n' "$1"; }
die() { printf '\nError: %s\n' "$1" >&2; exit 1; }

size_of() {
    if [ -f "$1" ]; then stat -f %z "$1"; else echo 0; fi
}

matches_hash() {
    [ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" = "$2" ]
}

# Downloads to a .part file and only replaces the real file once the checksum matches.
fetch_model() {
    local name="$1" url="$2" size="$3" sha="$4"
    local dest="$SUPPORT/$name"
    local part="$dest.part"
    local attempt=1

    if [ "$(size_of "$dest")" = "$size" ] && matches_hash "$dest" "$sha"; then
        echo "$name is already downloaded."
        return
    fi

    mkdir -p "$(dirname "$dest")"
    [ "$(size_of "$part")" -gt "$size" ] && rm -f "$part"

    echo "Downloading $name ($((size / 1000000)) MB)..."
    while [ "$(size_of "$part")" != "$size" ]; do
        if ! curl --fail --location --progress-bar --continue-at - --output "$part" "$url"; then
            [ "$attempt" -ge "$DOWNLOAD_ATTEMPTS" ] && die "Could not download $name. Check your internet connection, then run ./install.sh again to resume."
            attempt=$((attempt + 1))
            echo "Download interrupted, retrying..."
            sleep 3
        fi
    done

    if ! matches_hash "$part" "$sha"; then
        rm -f "$part"
        die "$name failed its checksum, so it was discarded. Run ./install.sh again to download it fresh."
    fi
    mv -f "$part" "$dest"
}

step "Checking this Mac"
[ "$(uname -m)" = "arm64" ] || die "VENWhispr needs an Apple Silicon Mac (M1 or newer)."
macos_major="$(sw_vers -productVersion | cut -d . -f 1)"
[ "$macos_major" -ge 14 ] || die "VENWhispr needs macOS 14 or newer. This Mac has $(sw_vers -productVersion)."
if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    die "Apple's Command Line Tools are missing. Finish the installer window that just opened, then run ./install.sh again."
fi
[ -x "$BREW" ] || die "Homebrew is missing. Install it from https://brew.sh, then run ./install.sh again."

needed_bytes=$SPARE_BYTES
for model in "${MODELS[@]}"; do
    IFS='|' read -r name _ size _ <<< "$model"
    if [ "$(size_of "$SUPPORT/$name")" != "$size" ]; then
        needed_bytes=$((needed_bytes + size - $(size_of "$SUPPORT/$name.part")))
    fi
done
free_kb="$(df -k "$HOME" | awk 'NR==2 {print $4}')"
if [ "$((free_kb * 1024))" -lt "$needed_bytes" ]; then
    die "Not enough free disk space. This needs about $((needed_bytes / 1000000000)) GB, and $((free_kb / 1000000)) GB is free."
fi
echo "Looks good."

step "Installing the speech and punctuation servers"
if [ -x /opt/homebrew/bin/whisper-server ] && [ -x /opt/homebrew/bin/llama-server ]; then
    echo "Already installed."
else
    "$BREW" install whisper.cpp llama.cpp
fi

step "Downloading the models"
for model in "${MODELS[@]}"; do
    IFS='|' read -r name url size sha <<< "$model"
    fetch_model "$name" "$url" "$size" "$sha"
done

step "Building VENWhispr (this can take a few minutes)"
./build.sh install

cat <<'DONE'

==> VENWhispr is installed and running. Look for its icon in the menu bar.

Allow Microphone and Accessibility when asked, or turn them on in
System Settings > Privacy & Security. Accessibility is what lets it paste.

Hold Right Option to dictate in English, or Right Command for Romanian.
You can change the keys and languages from the menu bar icon.
DONE
