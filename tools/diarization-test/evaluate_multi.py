#!/usr/bin/env python3
"""Evaluate diarization across multiple recordings with bleed filtering."""

import json
import subprocess
import struct
import os
import sys
from collections import defaultdict

SAMPLE_RATE = 0.1


def load_segments(path):
    with open(path) as f:
        data = json.load(f)
    return data["segments"], data["metadata"]


def get_rms_at_range(wav_path, start, end):
    result = subprocess.run(
        ['ffmpeg', '-y', '-i', wav_path, '-ss', str(start), '-to', str(end),
         '-f', 's16le', '-acodec', 'pcm_s16le', '-ar', '16000', '-ac', '1', '-'],
        capture_output=True, timeout=10
    )
    if not result.stdout:
        return 0.0
    samples = struct.unpack(f'<{len(result.stdout)//2}h', result.stdout)
    if not samples:
        return 0.0
    return (sum(s*s for s in samples) / len(samples)) ** 0.5


def filter_bleed(segs, own_wav, other_wav):
    filtered = []
    for seg in segs:
        own_rms = get_rms_at_range(own_wav, seg['start'], seg['end'])
        other_rms = get_rms_at_range(other_wav, seg['start'], seg['end'])
        if own_rms < 200 or (own_rms / max(other_rms, 1) < 0.3 and own_rms < 500):
            continue
        filtered.append(seg)
    return filtered


def build_timeline(segments, label):
    timeline = {}
    for seg in segments:
        for i in range(int(seg["start"] / SAMPLE_RATE), int(seg["end"] / SAMPLE_RATE)):
            timeline[i] = label
    return timeline


def evaluate(gt, mono_path):
    mono_segs, _ = load_segments(mono_path)
    diarized = {}
    for seg in mono_segs:
        for i in range(int(seg["start"] / SAMPLE_RATE), int(seg["end"] / SAMPLE_RATE)):
            diarized[i] = seg.get("speaker", "?")

    # Determine mapping
    votes = defaultdict(lambda: defaultdict(float))
    for i, gt_label in gt.items():
        if gt_label == "BOTH":
            continue
        if i in diarized:
            votes[diarized[i]][gt_label] += 1

    s1_L = votes.get("S1", {}).get("L", 0)
    s1_R = votes.get("S1", {}).get("R", 0)
    mapping = {"S1": "L", "S2": "R"} if s1_L >= s1_R else {"S1": "R", "S2": "L"}

    speech = {i for i, l in gt.items() if l in ("L", "R")}
    both = {i for i, l in gt.items() if l == "BOTH"}
    correct = wrong = missed = fa = 0

    for i in speech:
        if i in diarized:
            if mapping.get(diarized[i]) == gt[i]:
                correct += 1
            else:
                wrong += 1
        else:
            missed += 1

    for i in diarized:
        if i not in speech and i not in both:
            fa += 1

    total = correct + wrong + missed
    if total == 0:
        return None
    return {
        "segs": len(mono_segs),
        "acc": correct / total * 100,
        "conf": wrong / total * 100,
        "miss": missed / total * 100,
        "fa": fa / total * 100,
        "der": (wrong + missed + fa) / total * 100,
    }


def process_recording(rec_dir, label):
    left_wav = os.path.join(rec_dir, "left.wav")
    right_wav = os.path.join(rec_dir, "right.wav")
    left_json = os.path.join(rec_dir, "left.json")
    right_json = os.path.join(rec_dir, "right.json")

    if not os.path.exists(left_json) or not os.path.exists(right_json):
        print(f"  {label}: ground truth not ready yet")
        return

    left_segs, _ = load_segments(left_json)
    right_segs, _ = load_segments(right_json)

    # Filter bleed
    if os.path.exists(left_wav) and os.path.exists(right_wav):
        left_segs = filter_bleed(left_segs, left_wav, right_wav)
        right_segs = filter_bleed(right_segs, right_wav, left_wav)

    left_tl = build_timeline(left_segs, "L")
    right_tl = build_timeline(right_segs, "R")
    gt = {}
    for i in set(left_tl) | set(right_tl):
        l = i in left_tl
        r = i in right_tl
        gt[i] = "BOTH" if l and r else ("L" if l else "R")

    print(f"\n{'='*70}")
    print(f"  {label} (L:{len(left_segs)} segs, R:{len(right_segs)} segs)")
    print(f"{'='*70}")
    print(f"  {'Config':<25} {'Segs':>4} {'Acc%':>6} {'Conf%':>6} {'Miss%':>6} {'FA%':>6} {'DER%':>6}")
    print(f"  {'-'*70}")

    results = {}
    for fname in sorted(os.listdir(rec_dir)):
        if not fname.startswith("mono") or not fname.endswith(".json"):
            continue
        name = fname.replace("mono_", "").replace("mono", "baseline").replace(".json", "")
        path = os.path.join(rec_dir, fname)
        r = evaluate(gt, path)
        if r:
            results[name] = r
            print(f"  {name:<25} {r['segs']:>4} {r['acc']:>6.1f} {r['conf']:>6.1f} "
                  f"{r['miss']:>6.1f} {r['fa']:>6.1f} {r['der']:>6.1f}")

    return results


def main():
    dirs = [
        ("tools/diarization-test", "Rec1: 16:40 cl-altaluna-2 (17min)"),
        ("tools/diarization-test/rec2", "Rec2: 13:41 cl-altaluna-1 (32min)"),
        ("tools/diarization-test/rec3", "Rec3: 19:52 cl-altaluna-2 (28min)"),
    ]

    all_results = {}
    for d, label in dirs:
        if os.path.isdir(d):
            r = process_recording(d, label)
            if r:
                all_results[label] = r

    # Summary across all recordings
    if len(all_results) > 1:
        print(f"\n{'='*70}")
        print(f"  SUMMARY ACROSS RECORDINGS")
        print(f"{'='*70}")
        configs = set()
        for results in all_results.values():
            configs.update(results.keys())

        for config in sorted(configs):
            confs = [r[config]["conf"] for r in all_results.values() if config in r]
            ders = [r[config]["der"] for r in all_results.values() if config in r]
            if confs:
                print(f"  {config:<25} avg_conf={sum(confs)/len(confs):.1f}%  avg_der={sum(ders)/len(ders):.1f}%  (n={len(confs)})")


if __name__ == "__main__":
    main()
