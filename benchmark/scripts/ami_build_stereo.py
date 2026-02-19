#!/usr/bin/env python3
"""
Build simulated Ripcord-style stereo files from AMI individual headset recordings.

Simulates Ripcord's dual-channel recording setup:
  L channel = system audio (sum of "remote" speakers' headset mics)
  R channel = mic audio (one "local" speaker's headset, which in a real setup
              would also contain acoustic bleed from remote speakers)

For each meeting, iterates through speakers, treating each as the "local" speaker
in turn, producing one stereo WAV per speaker-as-local scenario.

This enables Tier 2 benchmarking: testing channel-aware diarization where the
system knows L=remote, R=local.

Usage:
    python ami_build_stereo.py <audio_dir> <output_dir> [meeting_id ...]

Requires: Python 3.8+ with 'wave' and 'struct' modules (stdlib only).
Audio files must be 16kHz 16-bit mono WAV (standard AMI format).
"""

import os
import sys
import wave
import struct
import glob
import re


def read_wav_mono(path):
    """Read a mono WAV file, return (sample_rate, samples as list of int16)."""
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1, (
            f"Expected mono, got {w.getnchannels()} channels: {path}"
        )
        assert w.getsampwidth() == 2, (
            f"Expected 16-bit, got {w.getsampwidth() * 8}-bit: {path}"
        )
        sr = w.getframerate()
        n = w.getnframes()
        raw = w.readframes(n)
        samples = list(struct.unpack(f"<{n}h", raw))
    return sr, samples


def write_wav_stereo(path, sample_rate, left, right):
    """Write a stereo WAV file from two mono sample lists."""
    n = min(len(left), len(right))
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        # Interleave L/R
        interleaved = []
        for i in range(n):
            interleaved.append(left[i])
            interleaved.append(right[i])
        w.writeframes(struct.pack(f"<{n * 2}h", *interleaved))


def mix_channels(channels):
    """Mix multiple mono channels by averaging, with clipping to int16 range."""
    if not channels:
        return []
    n = min(len(c) for c in channels)
    count = len(channels)
    mixed = []
    for i in range(n):
        s = sum(c[i] for c in channels) // count
        mixed.append(max(-32768, min(32767, s)))
    return mixed


def find_headset_files(audio_dir, meeting_id):
    """Find individual headset WAV files for a meeting.

    Returns dict: channel_id -> path (e.g., {"0": "ES2004a.Headset-0.wav", ...})
    """
    files = {}
    for ch in range(8):  # AMI has up to 4 speakers but search wider
        path = os.path.join(audio_dir, f"{meeting_id}.Headset-{ch}.wav")
        if os.path.exists(path):
            files[str(ch)] = path
    return files


def process_meeting(audio_dir, output_dir, meeting_id):
    """Build stereo files for one meeting, one per local-speaker scenario."""
    headsets = find_headset_files(audio_dir, meeting_id)
    if len(headsets) < 2:
        print(f"  {meeting_id}: only {len(headsets)} headset(s) found, skipping")
        return

    print(f"  {meeting_id}: {len(headsets)} headsets")

    # Read all channels
    channels = {}
    sample_rate = None
    for ch_id, path in headsets.items():
        sr, samples = read_wav_mono(path)
        if sample_rate is None:
            sample_rate = sr
        else:
            assert sr == sample_rate, f"Sample rate mismatch: {sr} vs {sample_rate}"
        channels[ch_id] = samples

    # For each speaker, create a stereo file where they are "local"
    for local_ch in sorted(channels.keys()):
        remote_chs = [channels[ch] for ch in sorted(channels.keys()) if ch != local_ch]
        remote_mix = mix_channels(remote_chs)
        local_audio = channels[local_ch]

        out_name = f"{meeting_id}.local-{local_ch}.wav"
        out_path = os.path.join(output_dir, out_name)
        write_wav_stereo(out_path, sample_rate, remote_mix, local_audio)
        print(f"    -> {out_name} (L=remote mix, R=headset-{local_ch})")


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <audio_dir> <output_dir> [meeting_id ...]")
        sys.exit(1)

    audio_dir = sys.argv[1]
    output_dir = sys.argv[2]
    meeting_ids = sys.argv[3:] if len(sys.argv) > 3 else None

    os.makedirs(output_dir, exist_ok=True)

    if meeting_ids is None:
        # Auto-discover from headset files
        pattern = os.path.join(audio_dir, "*.Headset-0.wav")
        meeting_ids = sorted(
            set(os.path.basename(f).split(".")[0] for f in glob.glob(pattern))
        )
        if not meeting_ids:
            print("ERROR: No headset files found")
            sys.exit(1)

    print(f"Building stereo files for {len(meeting_ids)} meetings...")
    for mid in meeting_ids:
        process_meeting(audio_dir, output_dir, mid)

    print("Done.")


if __name__ == "__main__":
    main()
