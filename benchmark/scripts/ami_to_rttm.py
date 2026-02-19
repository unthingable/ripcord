#!/usr/bin/env python3
"""
Convert AMI NXT word-level annotations to RTTM format.

AMI annotations use NXT XML with per-speaker word files:
  annotations/<meeting>.<speaker>.words.xml

Each word has start/end times. We merge consecutive words from the same
speaker into speech segments (collapsing gaps < 0.3s), then output RTTM.

Usage:
    python ami_to_rttm.py <annotations_dir> <output_dir> [meeting_id ...]

If no meeting IDs given, processes all meetings found in annotations.
"""

import os
import sys
import glob
import re
from xml.etree import ElementTree as ET
from collections import defaultdict


def parse_words_file(path):
    """Parse an AMI .words.xml file, returning list of (start, end, word)."""
    words = []
    try:
        tree = ET.parse(path)
    except ET.ParseError as e:
        print(f"  WARNING: Failed to parse {path}: {e}", file=sys.stderr)
        return words

    for w in tree.iter("w"):
        start = w.get("starttime")
        end = w.get("endtime")
        if start is not None and end is not None:
            try:
                words.append((float(start), float(end)))
            except ValueError:
                continue
    return words


def words_to_segments(words, merge_gap=0.3):
    """Merge word timings into contiguous speech segments.

    Consecutive words with gaps < merge_gap seconds are merged into one segment.
    """
    if not words:
        return []
    words.sort(key=lambda x: x[0])
    segments = []
    seg_start, seg_end = words[0]
    for start, end in words[1:]:
        if start - seg_end < merge_gap:
            seg_end = max(seg_end, end)
        else:
            segments.append((seg_start, seg_end))
            seg_start, seg_end = start, end
    segments.append((seg_start, seg_end))
    return segments


def process_meeting(annotations_dir, meeting_id):
    """Process a single meeting, returning RTTM lines."""
    # Find all word files for this meeting
    # Pattern: <meeting>.<speaker>.words.xml
    pattern = os.path.join(annotations_dir, "words", f"{meeting_id}.*.words.xml")
    word_files = glob.glob(pattern)

    if not word_files:
        # Try without the 'words' subdirectory
        pattern = os.path.join(annotations_dir, f"{meeting_id}.*.words.xml")
        word_files = glob.glob(pattern)

    if not word_files:
        print(f"  WARNING: No word files found for {meeting_id}", file=sys.stderr)
        return []

    rttm_lines = []
    for wf in word_files:
        # Extract speaker ID from filename
        basename = os.path.basename(wf)
        # Pattern: ES2004a.A.words.xml -> speaker = A
        match = re.match(rf"^{re.escape(meeting_id)}\.(.+?)\.words\.xml$", basename)
        if not match:
            continue
        speaker = match.group(1)

        words = parse_words_file(wf)
        segments = words_to_segments(words)

        for start, end in segments:
            duration = end - start
            if duration < 0.01:
                continue
            # RTTM format: SPEAKER <file> <channel> <start> <duration> <NA> <NA> <speaker> <NA> <NA>
            rttm_lines.append(
                f"SPEAKER {meeting_id} 1 {start:.3f} {duration:.3f} <NA> <NA> {speaker} <NA> <NA>"
            )

    # Sort by start time
    rttm_lines.sort(key=lambda l: float(l.split()[3]))
    return rttm_lines


def find_meetings(annotations_dir):
    """Discover all meeting IDs from the annotations directory."""
    words_dir = os.path.join(annotations_dir, "words")
    search_dir = words_dir if os.path.isdir(words_dir) else annotations_dir

    meetings = set()
    for f in glob.glob(os.path.join(search_dir, "*.words.xml")):
        basename = os.path.basename(f)
        # Extract meeting ID (everything before the first speaker label)
        # ES2004a.A.words.xml -> ES2004a
        parts = basename.split(".")
        if len(parts) >= 3:
            meetings.add(parts[0])
    return sorted(meetings)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <annotations_dir> <output_dir> [meeting_id ...]")
        sys.exit(1)

    annotations_dir = sys.argv[1]
    output_dir = sys.argv[2]
    meeting_ids = sys.argv[3:] if len(sys.argv) > 3 else None

    if not os.path.isdir(annotations_dir):
        print(f"ERROR: Annotations directory not found: {annotations_dir}")
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    if meeting_ids is None:
        meeting_ids = find_meetings(annotations_dir)
        if not meeting_ids:
            print("ERROR: No meetings found in annotations directory")
            sys.exit(1)

    print(f"Processing {len(meeting_ids)} meetings...")
    for mid in meeting_ids:
        rttm_lines = process_meeting(annotations_dir, mid)
        if rttm_lines:
            out_path = os.path.join(output_dir, f"{mid}.rttm")
            with open(out_path, "w") as f:
                f.write("\n".join(rttm_lines) + "\n")
            print(f"  {mid}: {len(rttm_lines)} segments")
        else:
            print(f"  {mid}: no segments (skipped)")


if __name__ == "__main__":
    main()
