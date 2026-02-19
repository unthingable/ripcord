#!/usr/bin/env bash
#
# Ripcord Diarization Benchmark Suite
#
# Downloads benchmark datasets, runs transcription, and computes DER scores.
#
# Usage:
#   ./benchmark.sh download [--quick|--full]          Download benchmark data
#   ./benchmark.sh prepare                             Convert annotations to RTTM
#   ./benchmark.sh run [--quick] [dataset]             Run transcription on benchmarks
#   ./benchmark.sh score [dataset]                     Compute DER scores
#   ./benchmark.sh compress [--force]                  Transcode WAV->M4A to save space
#   ./benchmark.sh all [--quick] [--compress]          Download, prepare, compress, run, score
#
# Datasets: ami, voxconverse, all (default: all)
#
# Data is stored in ./data/ (gitignored). Results go to ./results/.
#
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$BENCH_DIR/scripts"
LISTS="$BENCH_DIR/lists"
DATA="$BENCH_DIR/data"
RESULTS="$BENCH_DIR/results"
REPO_ROOT="$(cd "$BENCH_DIR/.." && pwd)"

# Resolve transcribe binary
TRANSCRIBE="${TRANSCRIBE_BIN:-}"
if [[ -z "$TRANSCRIBE" ]]; then
    # Try release build first, then debug
    for candidate in \
        "$REPO_ROOT/.build/release/transcribe" \
        "$REPO_ROOT/.build/debug/transcribe" \
        "$REPO_ROOT/Ripcord.app/Contents/MacOS/transcribe"; do
        if [[ -x "$candidate" ]]; then
            TRANSCRIBE="$candidate"
            break
        fi
    done
fi

usage() {
    sed -n '3,14s/^# //p' "$0"
    exit 1
}

# ─── download ────────────────────────────────────────────────────────────────

cmd_download() {
    local mode="${1:---quick}"
    mkdir -p "$DATA"

    case "$mode" in
        --quick)
            echo "==> Downloading benchmark data (quick mode: ~300MB)"
            echo
            # AMI: only the 5 quick-list meetings (SDM)
            echo "--- AMI (quick subset, SDM only) ---"
            bash "$SCRIPTS/download_ami.sh" "$DATA"
            echo
            echo "--- VoxConverse (quick subset) ---"
            bash "$SCRIPTS/download_voxconverse.sh" "$DATA" --quick
            ;;
        --full)
            echo "==> Downloading benchmark data (full mode: ~1.2GB)"
            echo
            echo "--- AMI (full test split, SDM + IHM) ---"
            bash "$SCRIPTS/download_ami.sh" "$DATA" --ihm
            echo
            echo "--- VoxConverse (full dev set) ---"
            bash "$SCRIPTS/download_voxconverse.sh" "$DATA"
            ;;
        *)
            echo "Unknown download mode: $mode (use --quick or --full)"
            exit 1
            ;;
    esac

    echo
    echo "Download complete. Data stored in $DATA/"
    du -sh "$DATA"/* 2>/dev/null || true
}

# ─── prepare ─────────────────────────────────────────────────────────────────

cmd_prepare() {
    echo "==> Preparing benchmark ground truth"
    echo

    # Convert AMI NXT annotations to RTTM
    local ami_anno="$DATA/ami/annotations"
    local ami_rttm="$DATA/ami/rttm"
    if [[ -d "$ami_anno" ]]; then
        echo "--- Converting AMI annotations to RTTM ---"
        mkdir -p "$ami_rttm"

        # Read meeting list (use whatever was downloaded)
        local meetings=()
        for list_file in "$LISTS/ami_test.txt"; do
            while IFS= read -r line; do
                [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
                meetings+=("$line")
            done < "$list_file"
        done

        local existing_rttm=0
        for m in "${meetings[@]}"; do
            [[ -f "$ami_rttm/${m}.rttm" ]] && existing_rttm=$(( existing_rttm + 1 ))
        done
        if [[ "$existing_rttm" -eq "${#meetings[@]}" ]]; then
            echo "  -> RTTM files already exist ($existing_rttm files), skipping conversion."
        else
            python3 "$SCRIPTS/ami_to_rttm.py" "$ami_anno" "$ami_rttm" "${meetings[@]}"
            echo "  -> $(ls "$ami_rttm"/*.rttm 2>/dev/null | wc -l | tr -d ' ') RTTM files in $ami_rttm/"
        fi
    else
        echo "  AMI annotations not found, skipping. Run 'download' first."
    fi

    # VoxConverse RTTMs are already in the right format
    if [[ -d "$DATA/voxconverse/rttm" ]]; then
        echo "--- VoxConverse RTTM files already in standard format ---"
        echo "  $(ls "$DATA/voxconverse/rttm/"*.rttm 2>/dev/null | wc -l | tr -d ' ') files"
    fi

    # Build stereo test files if IHM data exists
    local ihm_count
    ihm_count=$(ls "$DATA/ami/audio/"*.Headset-0.wav 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ihm_count" -gt 0 ]]; then
        echo
        echo "--- Building Tier 2 stereo test files from AMI IHM ---"
        if [[ -d "$DATA/ami/stereo" ]] && ls "$DATA/ami/stereo"/*.wav "$DATA/ami/stereo"/*.m4a &>/dev/null 2>&1; then
            echo "  -> Stereo files already exist in $DATA/ami/stereo/, skipping."
        else
            mkdir -p "$DATA/ami/stereo"
            python3 "$SCRIPTS/ami_build_stereo.py" "$DATA/ami/audio" "$DATA/ami/stereo"
        fi
    fi

    echo
    echo "Preparation complete."
}

# ─── compress ────────────────────────────────────────────────────────────────

cmd_compress() {
    local force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    if ! command -v afconvert &>/dev/null; then
        echo "ERROR: 'afconvert' not found. This command requires macOS."
        exit 1
    fi

    local total_files=0
    local total_saved=0

    compress_wav() {
        local wav="$1"
        local m4a="${wav%.wav}.m4a"

        local before
        before=$(stat -f%z "$wav" 2>/dev/null || stat -c%s "$wav" 2>/dev/null || echo 0)

        afconvert -f m4af -d aac -b 48000 "$wav" "$m4a"

        if [[ -f "$m4a" && -s "$m4a" ]]; then
            local after
            after=$(stat -f%z "$m4a" 2>/dev/null || stat -c%s "$m4a" 2>/dev/null || echo 0)
            local saved=$(( before - after ))
            local before_mb=$(( before / 1048576 ))
            local after_mb=$(( after / 1048576 ))
            echo "  $(basename "$wav") -> .m4a (${before_mb}MB -> ${after_mb}MB)"
            rm -f "$wav"
            total_files=$(( total_files + 1 ))
            total_saved=$(( total_saved + saved ))
        else
            echo "  ERROR: failed to create $m4a, keeping WAV"
            rm -f "$m4a"
        fi
    }

    # Check for IHM WAV files and stereo directory
    local ihm_wavs=()
    while IFS= read -r -d '' f; do
        ihm_wavs+=("$f")
    done < <(find "$DATA/ami/audio" -maxdepth 1 -name '*.Headset-[0-9].wav' -print0 2>/dev/null)

    local stereo_has_files=false
    if [[ -d "$DATA/ami/stereo" ]] && ls "$DATA/ami/stereo"/*.m4a "$DATA/ami/stereo"/*.wav &>/dev/null 2>&1; then
        stereo_has_files=true
    fi

    if [[ ${#ihm_wavs[@]} -gt 0 ]] && ! $stereo_has_files; then
        if ! $force; then
            echo "WARNING: IHM WAV files found but stereo not yet built."
            echo "  Run 'benchmark.sh prepare' first, or pass --force to compress IHM files anyway."
        fi
    fi

    # AMI SDM (Mix-Headset) WAVs
    if [[ -d "$DATA/ami/audio" ]]; then
        local sdm_found=false
        for wav in "$DATA/ami/audio"/*.Mix-Headset.wav; do
            [[ -f "$wav" ]] || continue
            sdm_found=true
            compress_wav "$wav"
        done
        $sdm_found || true
    fi

    # AMI IHM WAVs — only if stereo is built or --force
    if [[ ${#ihm_wavs[@]} -gt 0 ]]; then
        if $stereo_has_files || $force; then
            for wav in "${ihm_wavs[@]}"; do
                compress_wav "$wav"
            done
        fi
    fi

    # VoxConverse WAVs
    if [[ -d "$DATA/voxconverse/audio" ]]; then
        for wav in "$DATA/voxconverse/audio"/*.wav; do
            [[ -f "$wav" ]] || continue
            compress_wav "$wav"
        done
    fi

    # Stereo WAVs (already built from IHM)
    if [[ -d "$DATA/ami/stereo" ]]; then
        for wav in "$DATA/ami/stereo"/*.wav; do
            [[ -f "$wav" ]] || continue
            compress_wav "$wav"
        done
    fi

    echo
    local saved_mb=$(( total_saved / 1048576 ))
    echo "Compression complete: $total_files file(s) compressed, ~${saved_mb}MB saved."
}

# ─── run ─────────────────────────────────────────────────────────────────────

cmd_run() {
    local quick=false
    local dataset="all"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick) quick=true; shift ;;
            *) dataset="$1"; shift ;;
        esac
    done

    if [[ -z "$TRANSCRIBE" ]]; then
        echo "ERROR: Cannot find 'transcribe' binary."
        echo "  Build it first: make build"
        echo "  Or set TRANSCRIBE_BIN=/path/to/transcribe"
        exit 1
    fi
    echo "Using: $TRANSCRIBE"
    echo

    # AMI
    if [[ "$dataset" == "all" || "$dataset" == "ami" ]]; then
        local ami_audio="$DATA/ami/audio"
        local ami_sys="$RESULTS/ami/sys"
        mkdir -p "$ami_sys"

        local list_file
        if $quick; then
            list_file="$LISTS/ami_quick.txt"
        else
            list_file="$LISTS/ami_test.txt"
        fi

        echo "--- Transcribing AMI meetings ---"
        while IFS= read -r meeting; do
            [[ "$meeting" =~ ^#.*$ || -z "$meeting" ]] && continue
            local audio=""
            for ext in m4a wav; do
                [[ -f "$ami_audio/${meeting}.Mix-Headset.${ext}" ]] && audio="$ami_audio/${meeting}.Mix-Headset.${ext}" && break
            done
            local out_json="$ami_sys/${meeting}.json"
            local out_rttm="$ami_sys/${meeting}.rttm"

            if [[ -f "$out_rttm" ]]; then
                echo "  $meeting: already processed"
                continue
            fi

            if [[ -z "$audio" ]]; then
                echo "  $meeting: audio not found, skipping"
                continue
            fi

            echo "  $meeting: transcribing..."
            "$TRANSCRIBE" "$audio" --format json -o "$out_json" --force 2>&1 | \
                sed 's/^/    /'

            # Convert to RTTM
            python3 "$SCRIPTS/json_to_rttm.py" "$out_json" "$out_rttm"
        done < "$list_file"
    fi

    # VoxConverse
    if [[ "$dataset" == "all" || "$dataset" == "voxconverse" ]]; then
        local vc_audio="$DATA/voxconverse/audio"
        local vc_sys="$RESULTS/voxconverse/sys"
        mkdir -p "$vc_sys"

        echo "--- Transcribing VoxConverse clips ---"
        local vc_list
        if $quick; then
            vc_list="$LISTS/voxconverse_quick.txt"
        else
            # Process all available audio
            vc_list=""
        fi

        if [[ -n "$vc_list" ]]; then
            while IFS= read -r clip; do
                [[ "$clip" =~ ^#.*$ || -z "$clip" ]] && continue
                run_voxconverse_file "$vc_audio" "$vc_sys" "$clip"
            done < "$vc_list"
        else
            for audio_file in "$vc_audio"/*.m4a "$vc_audio"/*.wav; do
                [[ -f "$audio_file" ]] || continue
                local clip ext
                ext="${audio_file##*.}"
                clip=$(basename "$audio_file" ".$ext")
                # Skip WAV if an M4A for same clip already handled
                [[ "$ext" == "wav" && -f "$vc_audio/${clip}.m4a" ]] && continue
                run_voxconverse_file "$vc_audio" "$vc_sys" "$clip"
            done
        fi
    fi

    echo
    echo "Transcription complete. Results in $RESULTS/"
}

run_voxconverse_file() {
    local audio_dir="$1" sys_dir="$2" clip="$3"
    local audio=""
    for ext in m4a wav; do
        [[ -f "$audio_dir/${clip}.${ext}" ]] && audio="$audio_dir/${clip}.${ext}" && break
    done
    local out_json="$sys_dir/${clip}.json"
    local out_rttm="$sys_dir/${clip}.rttm"

    if [[ -f "$out_rttm" ]]; then
        echo "  $clip: already processed"
        return
    fi

    if [[ -z "$audio" ]]; then
        echo "  $clip: audio not found, skipping"
        return
    fi

    echo "  $clip: transcribing..."
    "$TRANSCRIBE" "$audio" --format json -o "$out_json" --force 2>&1 | \
        sed 's/^/    /'
    python3 "$SCRIPTS/json_to_rttm.py" "$out_json" "$out_rttm"
}

# ─── score ───────────────────────────────────────────────────────────────────

cmd_score() {
    local dataset="${1:-all}"

    echo "==> Computing DER scores"
    echo

    if [[ "$dataset" == "all" || "$dataset" == "ami" ]]; then
        local ami_ref="$DATA/ami/rttm"
        local ami_sys="$RESULTS/ami/sys"
        if [[ -d "$ami_ref" && -d "$ami_sys" ]]; then
            echo "=== AMI Meeting Corpus ==="
            echo "  (pyannote community-1 baseline: SDM ~19.9%, IHM ~17.0%)"
            echo
            python3 "$SCRIPTS/score.py" "$ami_ref" "$ami_sys" --per-file
        else
            echo "AMI: ref or sys RTTM not found. Run 'prepare' and 'run' first."
        fi
        echo
    fi

    if [[ "$dataset" == "all" || "$dataset" == "voxconverse" ]]; then
        local vc_ref="$DATA/voxconverse/rttm"
        local vc_sys="$RESULTS/voxconverse/sys"
        if [[ -d "$vc_ref" && -d "$vc_sys" ]]; then
            echo "=== VoxConverse Dev Set ==="
            echo "  (pyannote community-1 baseline: ~11.2%)"
            echo
            python3 "$SCRIPTS/score.py" "$vc_ref" "$vc_sys" --per-file
        else
            echo "VoxConverse: ref or sys RTTM not found. Run 'download' and 'run' first."
        fi
        echo
    fi
}

# ─── all ─────────────────────────────────────────────────────────────────────

cmd_all() {
    local mode="--quick"
    local do_compress=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full)     mode="--full"; shift ;;
            --quick)    mode="--quick"; shift ;;
            --compress) do_compress=true; shift ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    local quick_flag=""
    [[ "$mode" == "--quick" ]] && quick_flag="--quick"

    cmd_download "$mode"
    echo
    cmd_prepare
    echo
    if $do_compress; then
        cmd_compress
        echo
    fi
    cmd_run $quick_flag
    echo
    cmd_score
}

# ─── main ────────────────────────────────────────────────────────────────────

cmd="${1:-}"
shift || true

case "$cmd" in
    download) cmd_download "$@" ;;
    prepare)  cmd_prepare "$@" ;;
    run)      cmd_run "$@" ;;
    score)    cmd_score "$@" ;;
    compress) cmd_compress "$@" ;;
    all)      cmd_all "$@" ;;
    *)        usage ;;
esac
