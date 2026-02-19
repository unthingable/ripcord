#!/usr/bin/env bash
#
# Download VoxConverse dev set audio and RTTM annotations.
#
# Usage:
#   ./download_voxconverse.sh <data_dir> [--quick]
#
# --quick: Only download audio files listed in voxconverse_quick.txt
#          (5 clips, ~200MB instead of ~1.5GB for full dev set)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIST_DIR="$SCRIPT_DIR/../lists"
DATA_DIR="${1:?Usage: $0 <data_dir> [--quick]}"
QUICK=false
[[ "${2:-}" == "--quick" ]] && QUICK=true

VC_AUDIO_URL="https://www.robots.ox.ac.uk/~vgg/data/voxconverse/data/voxconverse_dev_wav.zip"
VC_RTTM_REPO="https://raw.githubusercontent.com/joonson/voxconverse/master/dev"

mkdir -p "$DATA_DIR/voxconverse/audio" "$DATA_DIR/voxconverse/rttm"

# --- RTTM annotations (tiny, always download all) ---
echo "Downloading VoxConverse RTTM annotations..."
if $QUICK; then
    while IFS= read -r clip; do
        [[ "$clip" =~ ^#.*$ || -z "$clip" ]] && continue
        rttm="$DATA_DIR/voxconverse/rttm/${clip}.rttm"
        if [[ -f "$rttm" ]]; then
            echo "  $clip.rttm: already exists"
            continue
        fi
        curl -sL -o "$rttm" "$VC_RTTM_REPO/${clip}.rttm"
        echo "  $clip.rttm"
    done < "$LIST_DIR/voxconverse_quick.txt"
else
    # Clone all dev RTTMs
    TMP_DIR=$(mktemp -d)
    echo "  Cloning RTTM repo..."
    git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/joonson/voxconverse.git "$TMP_DIR/vc" 2>/dev/null
    (cd "$TMP_DIR/vc" && git sparse-checkout set dev)
    cp "$TMP_DIR/vc/dev/"*.rttm "$DATA_DIR/voxconverse/rttm/"
    rm -rf "$TMP_DIR"
    echo "  $(ls "$DATA_DIR/voxconverse/rttm/"*.rttm 2>/dev/null | wc -l | tr -d ' ') RTTM files."
fi

# --- Audio ---
if $QUICK; then
    echo "Downloading VoxConverse audio (quick subset)..."
    # Download full zip, extract only the clips we need, then clean up
    ZIP="$DATA_DIR/voxconverse/voxconverse_dev_wav.zip"
    if [[ ! -f "$ZIP" ]]; then
        # Check if we already have all the quick clips
        ALL_PRESENT=true
        while IFS= read -r clip; do
            [[ "$clip" =~ ^#.*$ || -z "$clip" ]] && continue
            [[ ! -f "$DATA_DIR/voxconverse/audio/${clip}.wav" ]] && ALL_PRESENT=false && break
        done < "$LIST_DIR/voxconverse_quick.txt"

        if $ALL_PRESENT; then
            echo "  All quick clips already present."
        else
            echo "  Downloading full dev zip (will extract subset)..."
            curl -L --progress-bar -o "$ZIP" "$VC_AUDIO_URL"
            while IFS= read -r clip; do
                [[ "$clip" =~ ^#.*$ || -z "$clip" ]] && continue
                echo "  Extracting $clip.wav..."
                unzip -q -j -o "$ZIP" "voxconverse_dev_wav/${clip}.wav" \
                    -d "$DATA_DIR/voxconverse/audio/" 2>/dev/null || \
                unzip -q -j -o "$ZIP" "audio/${clip}.wav" \
                    -d "$DATA_DIR/voxconverse/audio/" 2>/dev/null || \
                unzip -q -j -o "$ZIP" "${clip}.wav" \
                    -d "$DATA_DIR/voxconverse/audio/" 2>/dev/null || \
                echo "  WARNING: Could not find ${clip}.wav in archive"
            done < "$LIST_DIR/voxconverse_quick.txt"
            rm -f "$ZIP"
        fi
    fi
else
    echo "Downloading VoxConverse audio (full dev set)..."
    ZIP="$DATA_DIR/voxconverse/voxconverse_dev_wav.zip"
    if [[ $(ls "$DATA_DIR/voxconverse/audio/"*.wav 2>/dev/null | wc -l) -gt 200 ]]; then
        echo "  Audio files already present ($(ls "$DATA_DIR/voxconverse/audio/"*.wav | wc -l | tr -d ' ') files)."
    else
        curl -L --progress-bar -o "$ZIP" "$VC_AUDIO_URL"
        echo "  Extracting..."
        unzip -q -j -o "$ZIP" -d "$DATA_DIR/voxconverse/audio/"
        rm -f "$ZIP"
        echo "  $(ls "$DATA_DIR/voxconverse/audio/"*.wav 2>/dev/null | wc -l | tr -d ' ') audio files."
    fi
fi

echo "VoxConverse download complete."
echo "  Audio: $DATA_DIR/voxconverse/audio/"
echo "  RTTM:  $DATA_DIR/voxconverse/rttm/"
