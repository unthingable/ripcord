# Ripcord

macOS menubar app for retroactive audio recording with transcription.

## Features

- **Retroactive circular buffer** — 1–15 min configurable; save audio that already happened
- **System audio + microphone** capture with live mixing
- **Capture duration scrubber** — drag to select how much of the buffer to keep
- **Mic device selection** — choose input device from the menubar
- **WAV and M4A output** with configurable quality
- **Silence auto-pause** — automatically pauses recording during silence
- **Built-in transcription** with speaker diarization (via [FluidAudio](https://github.com/FluidInference/FluidAudio))
- **Transcript formats** — txt, md, json, srt, vtt
- **Filler word removal** — strip um, uh, etc. from transcripts
- **`transcribe` CLI** for batch transcription
- **Global hotkey** — Cmd+Shift+R

## Requirements

- macOS 14.2+ (Sonoma)
- Apple Silicon
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

| Flag | Description |
|------|-------------|
| `--model` | ASR model version: v2 (English), v3 (multilingual, default) |
| `--format` | Output format: txt, md, json, srt, vtt |
| `-o, --output` | Output file path |
| `--no-diarize` | Skip speaker diarization |
| `--num-speakers` | Exact speaker count hint |
| `--min-speakers` | Minimum speaker count hint |
| `--max-speakers` | Maximum speaker count hint |
| `--sensitivity` | Diarization sensitivity 0.0–1.0 (higher = more speakers) |
| `--speech-threshold` | Speech detection threshold 0.0–1.0 (lower = more sensitive) |
| `--min-segment` | Minimum segment duration in seconds |
| `--min-gap` | Minimum gap duration in seconds |
| `--fast` | Use fast diarization quality (default: balanced) |
| `--remove-fillers` | Remove filler words (um, uh, etc.) |
| `--range` | Time range as start-end (e.g. `5:00-7:30`, `300-450`, `5:00-`) |
| `--force` | Overwrite existing output file |
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
  test_components.swift          # unit tests
  test_e2e.swift                 # end-to-end (requires audio permissions)
  TranscribeKitTests/            # TranscribeKit unit tests
```

## Testing

```
make test         # unit tests
make test-e2e     # end-to-end (requires audio permissions)
```
