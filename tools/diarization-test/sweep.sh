#!/bin/bash
# Parameter sweep for diarization tuning
# Varies one parameter at a time from baseline

set -e
DIR="tools/diarization-test"
MONO="$DIR/mono.m4a"

# Baseline: sensitivity=0.75, speech-threshold=0.5, min-segment=0.1, balanced
# Already have: $DIR/mono.json

run_config() {
    local name="$1"
    shift
    local out="$DIR/mono_${name}.json"
    if [ -f "$out" ]; then
        echo "SKIP $name (already exists)"
        return
    fi
    echo "RUN  $name: $@"
    swift run transcribe --num-speakers 2 --format json --remove-fillers \
        "$@" -o "$out" "$MONO" 2>&1 | grep -E "(Error|Output)" || true
}

# Sensitivity sweep (clustering threshold)
run_config "sens_0.50" --sensitivity 0.50
run_config "sens_0.60" --sensitivity 0.60
run_config "sens_0.90" --sensitivity 0.90

# Speech threshold sweep
run_config "speech_0.30" --speech-threshold 0.30
run_config "speech_0.70" --speech-threshold 0.70

# Min-segment sweep
run_config "minseg_0.05" --min-segment 0.05
run_config "minseg_0.30" --min-segment 0.30
run_config "minseg_0.50" --min-segment 0.50

# Min-gap sweep
run_config "mingap_0.50" --min-gap 0.50
run_config "mingap_1.00" --min-gap 1.00

# Fast mode (stepRatio 0.2 instead of 0.05)
run_config "fast" --fast

# Combined: aggressive turn detection
run_config "aggressive" --sensitivity 0.90 --speech-threshold 0.30 --min-segment 0.05

echo "DONE"
