#!/usr/bin/env python3
"""
Diarization Error Rate (DER) scoring for Ripcord benchmarks.

Computes DER by comparing system RTTM output against reference RTTM ground truth.
Uses the standard interval-overlap method with configurable collar.

DER = (false alarm + missed speech + speaker confusion) / total reference speech

Does NOT require external dependencies (no dscore, no pyannote-metrics).
For more rigorous evaluation, install dscore and use it directly.

Usage:
    python score.py <ref_dir> <sys_dir> [--collar 0.25] [--skip-overlap]

    ref_dir: Directory of reference RTTM files
    sys_dir: Directory of system hypothesis RTTM files
    --collar: Forgiveness collar in seconds around reference boundaries (default: 0.25)
    --skip-overlap: Ignore overlapping speech regions in scoring
"""

import argparse
import glob
import os
import sys
from collections import defaultdict


def parse_rttm(path):
    """Parse an RTTM file into a list of (file_id, start, duration, speaker) tuples."""
    segments = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(";"):
                continue
            parts = line.split()
            if len(parts) < 9 or parts[0] != "SPEAKER":
                continue
            file_id = parts[1]
            start = float(parts[3])
            duration = float(parts[4])
            speaker = parts[7]
            segments.append((file_id, start, duration, speaker))
    return segments


def segments_to_frames(segments, frame_step=0.01):
    """Convert segments to frame-level speaker labels.

    Returns dict: frame_index -> set of speakers active at that frame.
    """
    frames = defaultdict(set)
    for _, start, duration, speaker in segments:
        start_frame = int(start / frame_step)
        end_frame = int((start + duration) / frame_step)
        for i in range(start_frame, end_frame):
            frames[i].add(speaker)
    return frames


def apply_collar(ref_segments, collar, frame_step=0.01):
    """Return set of frame indices within collar of any ref segment boundary."""
    collar_frames = set()
    collar_n = int(collar / frame_step)
    for _, start, duration, _ in ref_segments:
        start_frame = int(start / frame_step)
        end_frame = int((start + duration) / frame_step)
        for i in range(max(0, start_frame - collar_n), start_frame + collar_n + 1):
            collar_frames.add(i)
        for i in range(max(0, end_frame - collar_n), end_frame + collar_n + 1):
            collar_frames.add(i)
    return collar_frames


def compute_der(ref_segments, sys_segments, collar=0.25, skip_overlap=False):
    """Compute DER between reference and system segments for a single file.

    Returns (der, missed, false_alarm, confusion, total_ref) in seconds.
    """
    frame_step = 0.01  # 10ms frames

    ref_frames = segments_to_frames(ref_segments, frame_step)
    sys_frames = segments_to_frames(sys_segments, frame_step)

    collar_frames = (
        apply_collar(ref_segments, collar, frame_step) if collar > 0 else set()
    )

    # Determine scoring region: all frames with ref or sys speech
    all_frames = set(ref_frames.keys()) | set(sys_frames.keys())

    total_ref = 0
    missed = 0
    false_alarm = 0
    confusion = 0

    for frame in all_frames:
        if frame in collar_frames:
            continue

        ref_spk = ref_frames.get(frame, set())
        sys_spk = sys_frames.get(frame, set())

        if skip_overlap and len(ref_spk) > 1:
            continue

        n_ref = len(ref_spk)
        n_sys = len(sys_spk)

        if n_ref == 0 and n_sys > 0:
            false_alarm += n_sys
            continue

        total_ref += n_ref

        if n_sys == 0:
            missed += n_ref
            continue

        # For speaker confusion, we need optimal mapping.
        # Simple greedy: count how many sys speakers match ref speakers
        # (this is an approximation; full Hungarian would be more accurate
        # but for benchmarking purposes this is sufficient per-frame)
        n_correct = len(ref_spk & sys_spk)
        n_missed = n_ref - min(n_ref, n_sys)
        n_fa = max(0, n_sys - n_ref)
        n_conf = min(n_ref, n_sys) - n_correct

        missed += n_missed
        false_alarm += n_fa
        confusion += n_conf

    # Convert frame counts to seconds
    total_ref_s = total_ref * frame_step
    missed_s = missed * frame_step
    fa_s = false_alarm * frame_step
    conf_s = confusion * frame_step

    der = (missed_s + fa_s + conf_s) / total_ref_s if total_ref_s > 0 else 0.0
    return der, missed_s, fa_s, conf_s, total_ref_s


def find_optimal_mapping(ref_frames, sys_frames, all_frames, collar_frames):
    """Find optimal speaker mapping using total overlap duration.

    Returns dict mapping sys_speaker -> ref_speaker.
    """
    # Count co-occurrence between each (ref_speaker, sys_speaker) pair
    overlap = defaultdict(lambda: defaultdict(int))
    for frame in all_frames:
        if frame in collar_frames:
            continue
        ref_spk = ref_frames.get(frame, set())
        sys_spk = sys_frames.get(frame, set())
        for r in ref_spk:
            for s in sys_spk:
                overlap[s][r] += 1

    # Greedy mapping: assign each sys speaker to the ref speaker with most overlap
    mapping = {}
    used_ref = set()
    # Sort by total overlap descending for better greedy results
    sys_speakers = sorted(
        overlap.keys(), key=lambda s: max(overlap[s].values()), reverse=True
    )
    for s in sys_speakers:
        best_ref = max(overlap[s], key=lambda r: overlap[s][r])
        mapping[s] = best_ref
        used_ref.add(best_ref)

    return mapping


def compute_der_with_mapping(
    ref_segments, sys_segments, collar=0.25, skip_overlap=False
):
    """Compute DER with optimal speaker label mapping (since sys labels are arbitrary)."""
    frame_step = 0.01

    ref_frames = segments_to_frames(ref_segments, frame_step)
    sys_frames = segments_to_frames(sys_segments, frame_step)

    collar_frames = (
        apply_collar(ref_segments, collar, frame_step) if collar > 0 else set()
    )
    all_frames = set(ref_frames.keys()) | set(sys_frames.keys())

    # Find optimal mapping
    mapping = find_optimal_mapping(ref_frames, sys_frames, all_frames, collar_frames)

    # Re-label sys frames
    mapped_sys_frames = defaultdict(set)
    for frame, speakers in sys_frames.items():
        for s in speakers:
            mapped_sys_frames[frame].add(mapping.get(s, s))

    total_ref = 0
    missed = 0
    false_alarm = 0
    confusion = 0

    for frame in all_frames:
        if frame in collar_frames:
            continue

        ref_spk = ref_frames.get(frame, set())
        sys_spk = mapped_sys_frames.get(frame, set())

        if skip_overlap and len(ref_spk) > 1:
            continue

        n_ref = len(ref_spk)
        n_sys = len(sys_spk)

        if n_ref == 0 and n_sys > 0:
            false_alarm += n_sys
            continue

        total_ref += n_ref

        if n_sys == 0:
            missed += n_ref
            continue

        n_correct = len(ref_spk & sys_spk)
        n_missed = n_ref - min(n_ref, n_sys)
        n_fa = max(0, n_sys - n_ref)
        n_conf = min(n_ref, n_sys) - n_correct

        missed += n_missed
        false_alarm += n_fa
        confusion += n_conf

    total_ref_s = total_ref * frame_step
    missed_s = missed * frame_step
    fa_s = false_alarm * frame_step
    conf_s = confusion * frame_step

    der = (missed_s + fa_s + conf_s) / total_ref_s if total_ref_s > 0 else 0.0
    return der, missed_s, fa_s, conf_s, total_ref_s


def main():
    parser = argparse.ArgumentParser(description="Compute Diarization Error Rate (DER)")
    parser.add_argument("ref_dir", help="Directory of reference RTTM files")
    parser.add_argument("sys_dir", help="Directory of system hypothesis RTTM files")
    parser.add_argument(
        "--collar", type=float, default=0.25, help="Collar in seconds (default: 0.25)"
    )
    parser.add_argument(
        "--skip-overlap", action="store_true", help="Skip overlapping speech in scoring"
    )
    parser.add_argument(
        "--per-file", action="store_true", help="Print per-file DER breakdown"
    )
    args = parser.parse_args()

    ref_files = {
        os.path.splitext(os.path.basename(f))[0]: f
        for f in glob.glob(os.path.join(args.ref_dir, "*.rttm"))
    }
    sys_files = {
        os.path.splitext(os.path.basename(f))[0]: f
        for f in glob.glob(os.path.join(args.sys_dir, "*.rttm"))
    }

    common = sorted(set(ref_files.keys()) & set(sys_files.keys()))
    if not common:
        print("ERROR: No matching RTTM files found between ref and sys directories.")
        print(f"  ref: {list(ref_files.keys())[:5]}...")
        print(f"  sys: {list(sys_files.keys())[:5]}...")
        sys.exit(1)

    only_ref = set(ref_files.keys()) - set(sys_files.keys())
    only_sys = set(sys_files.keys()) - set(ref_files.keys())
    if only_ref:
        print(
            f"WARNING: {len(only_ref)} ref files have no sys match: {sorted(only_ref)[:3]}..."
        )
    if only_sys:
        print(
            f"WARNING: {len(only_sys)} sys files have no ref match: {sorted(only_sys)[:3]}..."
        )

    total_missed = 0
    total_fa = 0
    total_conf = 0
    total_ref = 0

    print(
        f"Scoring {len(common)} files (collar={args.collar}s, skip_overlap={args.skip_overlap})"
    )
    print()

    if args.per_file:
        print(
            f"{'File':<25} {'DER':>7} {'Miss':>7} {'FA':>7} {'Conf':>7} {'Ref(s)':>8}"
        )
        print("-" * 65)

    for file_id in common:
        ref_segs = parse_rttm(ref_files[file_id])
        sys_segs = parse_rttm(sys_files[file_id])

        der, miss, fa, conf, ref_s = compute_der_with_mapping(
            ref_segs, sys_segs, collar=args.collar, skip_overlap=args.skip_overlap
        )

        if args.per_file:
            print(
                f"{file_id:<25} {der:>6.1%} {miss:>6.1f}s {fa:>6.1f}s {conf:>6.1f}s {ref_s:>7.1f}s"
            )

        total_missed += miss
        total_fa += fa
        total_conf += conf
        total_ref += ref_s

    total_der = (
        (total_missed + total_fa + total_conf) / total_ref if total_ref > 0 else 0.0
    )

    print()
    print("=" * 65)
    print(
        f"{'OVERALL':<25} {total_der:>6.1%} {total_missed:>6.1f}s {total_fa:>6.1f}s {total_conf:>6.1f}s {total_ref:>7.1f}s"
    )
    print()
    print(f"  Diarization Error Rate: {total_der:.1%}")
    print(
        f"  Missed Speech:          {total_missed:.1f}s ({total_missed / total_ref:.1%})"
    )
    print(f"  False Alarm:            {total_fa:.1f}s ({total_fa / total_ref:.1%})")
    print(f"  Speaker Confusion:      {total_conf:.1f}s ({total_conf / total_ref:.1%})")
    print(f"  Total Reference Speech: {total_ref:.1f}s")


if __name__ == "__main__":
    main()
