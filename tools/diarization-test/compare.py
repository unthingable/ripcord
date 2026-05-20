#!/usr/bin/env python3
"""Compare mono diarized transcript against stereo ground truth.

Ground truth: L and R channel transcripts (each is a single speaker).
Test: mono downmix with diarization (assigns S1/S2).

Method: sample the timeline at 100ms resolution. At each sample point,
determine who is speaking in ground truth (L, R, both, neither) and
who the diarizer thinks is speaking (S1, S2, none). Compute accuracy.
"""

import json
import sys
from collections import defaultdict

SAMPLE_RATE = 0.1  # 100ms resolution


def load_segments(path):
    with open(path) as f:
        data = json.load(f)
    return data["segments"], data["metadata"]


def build_timeline(segments, label, duration):
    """Return dict mapping sample_index -> label for all active samples."""
    timeline = {}
    for seg in segments:
        start_idx = int(seg["start"] / SAMPLE_RATE)
        end_idx = int(seg["end"] / SAMPLE_RATE)
        for i in range(start_idx, end_idx):
            timeline[i] = label
    return timeline


def merge_ground_truth(left_tl, right_tl):
    """Merge L and R timelines into ground truth."""
    all_indices = set(left_tl.keys()) | set(right_tl.keys())
    gt = {}
    for i in all_indices:
        l = i in left_tl
        r = i in right_tl
        if l and r:
            gt[i] = "BOTH"
        elif l:
            gt[i] = "L"
        elif r:
            gt[i] = "R"
    return gt


def build_diarized_timeline(segments, duration):
    """Return dict mapping sample_index -> speaker label."""
    timeline = {}
    for seg in segments:
        start_idx = int(seg["start"] / SAMPLE_RATE)
        end_idx = int(seg["end"] / SAMPLE_RATE)
        speaker = seg.get("speaker", "?")
        for i in range(start_idx, end_idx):
            timeline[i] = speaker
    return timeline


def determine_mapping(gt, diarized):
    """Figure out whether S1=L,S2=R or S1=R,S2=L based on overlap."""
    votes = defaultdict(lambda: defaultdict(float))
    for i, gt_label in gt.items():
        if gt_label == "BOTH":
            continue
        if i in diarized:
            votes[diarized[i]][gt_label] += 1

    print("\n=== Speaker mapping votes ===")
    for speaker, counts in sorted(votes.items()):
        total = sum(counts.values())
        for label, count in sorted(counts.items()):
            print(f"  {speaker} -> {label}: {count:.0f} samples ({count/total*100:.1f}%)")

    # Determine best mapping
    s1_L = votes.get("S1", {}).get("L", 0)
    s1_R = votes.get("S1", {}).get("R", 0)
    if s1_L >= s1_R:
        return {"S1": "L", "S2": "R"}
    else:
        return {"S1": "R", "S2": "L"}


def compute_metrics(gt, diarized, mapping):
    """Compute diarization accuracy metrics."""
    # Only evaluate samples where ground truth has speech
    speech_samples = {i for i, label in gt.items() if label in ("L", "R")}
    both_samples = {i for i, label in gt.items() if label == "BOTH"}

    correct = 0
    wrong_speaker = 0
    missed = 0  # ground truth has speech, diarizer says nothing
    false_alarm = 0  # diarizer says speech, ground truth says nothing
    overlap_correct = 0
    overlap_wrong = 0

    for i in speech_samples:
        gt_label = gt[i]
        if i in diarized:
            predicted_channel = mapping.get(diarized[i], "?")
            if predicted_channel == gt_label:
                correct += 1
            else:
                wrong_speaker += 1
        else:
            missed += 1

    # Check for false alarms (diarizer assigns speech where there is none)
    gt_all_speech = speech_samples | both_samples
    for i in diarized:
        if i not in gt_all_speech:
            false_alarm += 1

    # Evaluate overlap regions
    for i in both_samples:
        if i in diarized:
            overlap_correct += 1
        else:
            overlap_wrong += 1

    total = correct + wrong_speaker + missed
    print(f"\n=== Diarization Accuracy (at {SAMPLE_RATE*1000:.0f}ms resolution) ===")
    print(f"  Total speech samples (excl overlap): {total}")
    print(f"  Correct speaker:    {correct:5d}  ({correct/total*100:.1f}%)")
    print(f"  Wrong speaker:      {wrong_speaker:5d}  ({wrong_speaker/total*100:.1f}%)")
    print(f"  Missed speech:      {missed:5d}  ({missed/total*100:.1f}%)")
    print(f"  False alarm:        {false_alarm:5d}")
    print(f"  Overlap regions:    {len(both_samples):5d} samples")
    print(f"  Diarization Error Rate (DER): {(wrong_speaker + missed + false_alarm) / total * 100:.1f}%")
    print(f"  Speaker Confusion Rate:       {wrong_speaker / total * 100:.1f}%")

    return correct, wrong_speaker, missed, false_alarm


def analyze_errors(gt, diarized, mapping, left_segs, right_segs, mono_segs):
    """Find and display the worst error regions."""
    speech_samples = {i for i, label in gt.items() if label in ("L", "R")}

    # Find contiguous error regions
    errors = []
    current_error = None
    for i in sorted(speech_samples):
        gt_label = gt[i]
        is_error = False
        error_type = None

        if i in diarized:
            predicted = mapping.get(diarized[i], "?")
            if predicted != gt_label:
                is_error = True
                error_type = f"confused ({gt_label} heard as {predicted})"
        else:
            is_error = True
            error_type = f"missed ({gt_label})"

        if is_error:
            if current_error and i == current_error["end_idx"] + 1:
                current_error["end_idx"] = i
                current_error["count"] += 1
            else:
                if current_error:
                    errors.append(current_error)
                current_error = {
                    "start_idx": i,
                    "end_idx": i,
                    "count": 1,
                    "type": error_type,
                }
        else:
            if current_error:
                errors.append(current_error)
                current_error = None
    if current_error:
        errors.append(current_error)

    # Sort by size (worst first)
    errors.sort(key=lambda e: e["count"], reverse=True)

    print(f"\n=== Top 15 Error Regions ===")
    for e in errors[:15]:
        start_t = e["start_idx"] * SAMPLE_RATE
        end_t = (e["end_idx"] + 1) * SAMPLE_RATE
        dur = end_t - start_t
        mm_s = int(start_t) // 60
        ss_s = int(start_t) % 60
        mm_e = int(end_t) // 60
        ss_e = int(end_t) % 60
        print(
            f"  [{mm_s:02d}:{ss_s:02d}-{mm_e:02d}:{ss_e:02d}] ({dur:.1f}s) {e['type']}"
        )

    # Summary by error type
    confusion_time = sum(
        e["count"] for e in errors if "confused" in e["type"]
    ) * SAMPLE_RATE
    missed_time = sum(
        e["count"] for e in errors if "missed" in e["type"]
    ) * SAMPLE_RATE
    print(f"\n  Total confusion time: {confusion_time:.1f}s")
    print(f"  Total missed time:   {missed_time:.1f}s")


def main():
    import sys
    suffix = sys.argv[1] if len(sys.argv) > 1 else ""
    left_file = f"tools/diarization-test/left{suffix}.json"
    right_file = f"tools/diarization-test/right{suffix}.json"
    print(f"Using: {left_file}, {right_file}")
    left_segs, left_meta = load_segments(left_file)
    right_segs, right_meta = load_segments(right_file)
    mono_segs, mono_meta = load_segments("tools/diarization-test/mono.json")

    duration = mono_meta["duration"]

    print(f"Recording duration: {duration:.1f}s ({duration/60:.1f} min)")
    print(f"Left channel:  {len(left_segs)} segments")
    print(f"Right channel: {len(right_segs)} segments")
    print(f"Mono diarized: {len(mono_segs)} segments")

    left_tl = build_timeline(left_segs, "L", duration)
    right_tl = build_timeline(right_segs, "R", duration)
    gt = merge_ground_truth(left_tl, right_tl)
    diarized_tl = build_diarized_timeline(mono_segs, duration)

    mapping = determine_mapping(gt, diarized_tl)
    print(f"\n  Best mapping: {mapping}")

    compute_metrics(gt, diarized_tl, mapping)
    analyze_errors(gt, diarized_tl, mapping, left_segs, right_segs, mono_segs)


if __name__ == "__main__":
    main()
