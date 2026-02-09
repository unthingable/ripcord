# Changelog

## 0.3.0

- Start audio capture at app launch instead of waiting for first panel click
- Replace manual NSPanel with native SwiftUI Settings scene

## 0.2.0

- Live waveform and level meters during buffering and recording
- Mic device selection from the menubar
- Capture duration scrubber to select how much buffer to keep
- Silence auto-pause with configurable threshold and timeout
- Transcript format selection (txt, md, json, srt, vtt)
- Filler word removal
- Re-transcribe recordings with different settings
- Transcribe external audio files
- Fix diarization boundary bleed with snap-to-pause heuristic and config tuning
- Fix re-transcribe overwriting previous transcripts

## 0.1.0

- Initial release
- Retroactive circular buffer (1–15 min)
- System audio + microphone capture
- WAV and M4A output with configurable quality
- Built-in transcription with speaker diarization
- `transcribe` CLI for batch transcription
- Global hotkey (Cmd+Shift+R)
- Launch at login
