#!/usr/bin/env python3
"""Evaluate all sweep results against stereo ground truth."""

import json
import glob
import os
from collections import defaultdict

SAMPLE_RATE = 0.1
DIR = "tools/diarization-test"


def load_segments(path):
    with open(path) as f:
        data = json.load(f)
    return data["segments"], data["metadata"]


def build_timeline(segments, label):
    timeline = {}
    for seg in segments:
        start_idx = int(seg["start"] / SAMPLE_RATE)
        end_idx = int(seg["end"] / SAMPLE_RATE)
        for i in range(start_idx, end_idx):
            timeline[i] = label
    return timeline


def merge_ground_truth(left_tl, right_tl):
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


def build_diarized_timeline(segments):
    timeline = {}
    for seg in segments:
        start_idx = int(seg["start"] / SAMPLE_RATE)
        end_idx = int(seg["end"] / SAMPLE_RATE)
        speaker = seg.get("speaker", "?")
        for i in range(start_idx, end_idx):
            timeline[i] = speaker
    return timeline


def determine_mapping(gt, diarized):
    votes = defaultdict(lambda: defaultdict(float))
    for i, gt_label in gt.items():
        if gt_label == "BOTH":
            continue
        if i in diarized:
            votes[diarized[i]][gt_label] += 1

    s1_L = votes.get("S1", {}).get("L", 0)
    s1_R = votes.get("S1", {}).get("R", 0)
    if s1_L >= s1_R:
        return {"S1": "L", "S2": "R"}
    else:
        return {"S1": "R", "S2": "L"}


def evaluate(gt, mono_path):
    mono_segs, mono_meta = load_segments(mono_path)
    diarized_tl = build_diarized_timeline(mono_segs)
    mapping = determine_mapping(gt, diarized_tl)

    speech_samples = {i for i, label in gt.items() if label in ("L", "R")}
    both_samples = {i for i, label in gt.items() if label == "BOTH"}

    correct = 0
    wrong_speaker = 0
    missed = 0
    false_alarm = 0

    for i in speech_samples:
        gt_label = gt[i]
        if i in diarized_tl:
            predicted_channel = mapping.get(diarized_tl[i], "?")
            if predicted_channel == gt_label:
                correct += 1
            else:
                wrong_speaker += 1
        else:
            missed += 1

    gt_all_speech = speech_samples | both_samples
    for i in diarized_tl:
        if i not in gt_all_speech:
            false_alarm += 1

    total = correct + wrong_speaker + missed
    der = (wrong_speaker + missed + false_alarm) / total * 100 if total else 0
    confusion = wrong_speaker / total * 100 if total else 0
    miss_rate = missed / total * 100 if total else 0
    fa_rate = false_alarm / total * 100 if total else 0
    accuracy = correct / total * 100 if total else 0

    return {
        "segments": len(mono_segs),
        "accuracy": accuracy,
        "confusion": confusion,
        "miss": miss_rate,
        "fa": fa_rate,
        "der": der,
        "mapping": mapping,
    }


def main():
    left_segs, _ = load_segments(f"{DIR}/left_filtered.json")
    right_segs, _ = load_segments(f"{DIR}/right_filtered.json")

    left_tl = build_timeline(left_segs, "L")
    right_tl = build_timeline(right_segs, "R")
    gt = merge_ground_truth(left_tl, right_tl)

    mono_files = sorted(glob.glob(f"{DIR}/mono*.json"))

    print(f"{'Config':<22} {'Segs':>4} {'Acc%':>6} {'Conf%':>6} {'Miss%':>6} {'FA%':>6} {'DER%':>6}  Mapping")
    print("-" * 90)

    results = []
    for path in mono_files:
        name = os.path.basename(path).replace("mono", "").replace(".json", "")
        name = name.lstrip("_") or "baseline"
        try:
            r = evaluate(gt, path)
            results.append((name, r))
            print(
                f"{name:<22} {r['segments']:>4} {r['accuracy']:>6.1f} {r['confusion']:>6.1f} "
                f"{r['miss']:>6.1f} {r['fa']:>6.1f} {r['der']:>6.1f}  {r['mapping']}"
            )
        except Exception as e:
            print(f"{name:<22} ERROR: {e}")

    # Find best
    if results:
        best = min(results, key=lambda x: x[1]["der"])
        print(f"\nBest DER: {best[0]} ({best[1]['der']:.1f}%)")
        best_conf = min(results, key=lambda x: x[1]["confusion"])
        print(f"Best confusion: {best_conf[0]} ({best_conf[1]['confusion']:.1f}%)")


if __name__ == "__main__":
    main()
