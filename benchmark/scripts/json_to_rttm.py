#!/usr/bin/env python3
"""
Convert Ripcord JSON transcript output to RTTM format for DER scoring.

Ripcord's --format json produces:
{
  "metadata": { "duration": ..., "speakers": [...], "source_file": "..." },
  "segments": [
    { "start": 1.23, "end": 4.56, "text": "...", "speaker": "SPEAKER_00" },
    ...
  ]
}

This script converts those segments to RTTM lines:
  SPEAKER <file_id> 1 <start> <duration> <NA> <NA> <speaker> <NA> <NA>

Usage:
    python json_to_rttm.py <input.json> [output.rttm]

If output is omitted, prints to stdout.
"""

import json
import os
import sys


def json_to_rttm(json_path, file_id=None):
    """Convert a Ripcord JSON transcript to RTTM lines."""
    with open(json_path) as f:
        data = json.load(f)

    if file_id is None:
        source = data.get("metadata", {}).get("source_file", json_path)
        file_id = os.path.splitext(os.path.basename(source))[0]

    lines = []
    for seg in data.get("segments", []):
        start = seg["start"]
        end = seg["end"]
        speaker = seg.get("speaker") or "UNKNOWN"
        duration = end - start
        if duration < 0.01:
            continue
        lines.append(
            f"SPEAKER {file_id} 1 {start:.3f} {duration:.3f} <NA> <NA> {speaker} <NA> <NA>"
        )
    return lines


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input.json> [output.rttm]")
        sys.exit(1)

    json_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else None

    lines = json_to_rttm(json_path)
    text = "\n".join(lines) + "\n" if lines else ""

    if output_path:
        with open(output_path, "w") as f:
            f.write(text)
        print(f"Wrote {len(lines)} RTTM segments to {output_path}")
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
