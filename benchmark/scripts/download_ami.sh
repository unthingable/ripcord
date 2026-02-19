#!/usr/bin/env bash
#
# Download AMI Corpus audio and annotations for diarization benchmarking.
#
# Usage:
#   ./download_ami.sh <data_dir> [--ihm]
#
# Downloads:
#   - Headset mix (SDM) WAV files for all meetings in ami_test.txt
#   - Manual annotations (NXT XML) for the whole corpus
#   - Optionally: individual headset (IHM) WAVs for meetings in ami_ihm.txt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIST_DIR="$SCRIPT_DIR/../lists"
DATA_DIR="${1:?Usage: $0 <data_dir> [--ihm]}"
IHM=false
[[ "${2:-}" == "--ihm" ]] && IHM=true

AMI_BASE="https://groups.inf.ed.ac.uk/ami"
ANNOTATIONS_URL="$AMI_BASE/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"

mkdir -p "$DATA_DIR/ami/audio" "$DATA_DIR/ami/annotations"

# --- Annotations (one-time, 22MB) ---
ANNO_ZIP="$DATA_DIR/ami/annotations/ami_public_manual_1.6.2.zip"
if [[ ! -d "$DATA_DIR/ami/annotations/words" ]]; then
    echo "Downloading AMI annotations..."
    curl -L --progress-bar -o "$ANNO_ZIP" "$ANNOTATIONS_URL"
    unzip -q -o "$ANNO_ZIP" -d "$DATA_DIR/ami/annotations"
    rm -f "$ANNO_ZIP"
    echo "Annotations extracted."
else
    echo "AMI annotations already present, skipping."
fi

# --- Headset mix (SDM) audio ---
echo "Downloading AMI headset mix (SDM) audio..."
while IFS= read -r meeting; do
    [[ "$meeting" =~ ^#.*$ || -z "$meeting" ]] && continue
    wav="$DATA_DIR/ami/audio/${meeting}.Mix-Headset.wav"
    if [[ -f "$wav" ]]; then
        echo "  $meeting Mix-Headset: already exists"
        continue
    fi
    url="$AMI_BASE/AMICorpusMirror/amicorpus/${meeting}/audio/${meeting}.Mix-Headset.wav"
    echo "  $meeting Mix-Headset..."
    curl -L --progress-bar -o "$wav" "$url"
done < "$LIST_DIR/ami_test.txt"

# --- Individual headset (IHM) audio (optional, for Tier 2 channel-aware testing) ---
if $IHM; then
    echo "Downloading AMI individual headset (IHM) audio..."
    while IFS= read -r meeting; do
        [[ "$meeting" =~ ^#.*$ || -z "$meeting" ]] && continue
        for ch in 0 1 2 3; do
            wav="$DATA_DIR/ami/audio/${meeting}.Headset-${ch}.wav"
            if [[ -f "$wav" ]]; then
                echo "  $meeting Headset-$ch: already exists"
                continue
            fi
            url="$AMI_BASE/AMICorpusMirror/amicorpus/${meeting}/audio/${meeting}.Headset-${ch}.wav"
            echo "  $meeting Headset-$ch..."
            curl -L --progress-bar -o "$wav" "$url"
        done
    done < "$LIST_DIR/ami_ihm.txt"
fi

echo "AMI download complete."
echo "  Audio: $DATA_DIR/ami/audio/"
echo "  Annotations: $DATA_DIR/ami/annotations/"
