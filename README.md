# Ripcord

macOS menubar app for retroactive audio recording with transcription.

## Features

- **Retroactive circular buffer** — 1–15 min configurable; save audio that already happened
- **System audio + microphone** capture with live mixing
- **Survives audio device changes** (speakers ↔ AirPods) without dropping a recording
- **WAV and M4A output** with configurable quality
- **Silence auto-pause** — automatically pauses recording during silence
- **Built-in transcription** with speaker diarization (via [FluidAudio](https://github.com/FluidInference/FluidAudio))
- **`transcribe` CLI** for batch transcription (txt, md, json, srt, vtt)
- **Global hotkey** — Cmd+Shift+R

## Requirements

- macOS 14.2+ (Sonoma)
- Swift 6.0 toolchain (Command Line Tools)
- Permissions: Screen & System Audio Recording, Microphone (prompted on first use)

## Build & Install

```
make bundle       # build + create Ripcord.app
make install      # copy to ~/Applications
./build.sh        # test + build + install + launch (all-in-one)
```

## Code Signing

The `make bundle` target codesigns the app with a local identity named **"Ripcord Development"**. Creating this certificate avoids having to re-grant audio permissions after each rebuild.

To create it: open **Keychain Access → Certificate Assistant → Create a Certificate**, name it `Ripcord Development`, set type to **Code Signing**.

If you don't create the certificate, the build still works — the codesign step will just fail silently and you'll need to re-approve permissions each time.

## Transcribe CLI

Bundled inside `Ripcord.app/Contents/MacOS/transcribe`.

```
transcribe <audio-file> [options]
```

Key flags:

| Flag | Description |
|------|-------------|
| `--model` | ASR model version (default: v3) |
| `--format` | Output format: txt, md, json, srt, vtt |
| `-o, --output` | Output file path |
| `--no-diarize` | Skip speaker diarization |
| `--num-speakers` | Exact speaker count hint |
| `--sensitivity` | Diarization sensitivity 0.0–1.0 (higher = more speakers) |
| `-v, --verbose` | Print performance metrics |

Example:

```
transcribe recording.m4a --format md -o transcript.md --num-speakers 2
```

## Project Structure

```
Sources/
  Ripcord/            # menubar app (SwiftUI)
  TranscribeKit/      # transcription library (shared)
  transcribe/         # CLI executable
Tests/
  test_components.swift   # unit tests
  test_e2e.swift          # end-to-end (requires audio permissions)
```

## Testing

```
make test         # unit tests
make test-e2e     # end-to-end (requires audio permissions)
```
