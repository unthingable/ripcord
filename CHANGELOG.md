# Changelog

## 0.7.3

- Fix microphone capture failing on AirPods and other Bluetooth headsets
- Improve stability when switching audio devices during a session

## 0.7.2

- Fix microphone access flickering when plugging in or unplugging audio devices

## 0.7.1

- Fix rename text field not accepting spaces
- Auto-focus rename text field when entering rename mode
- Detect recordings added or removed outside the app

## 0.7.0

- Rename recordings after they finish instead of requiring a name upfront
- Menubar icon turns red while recording
- Add diarization benchmark tooling (parameter sweep, AMI/VoxConverse datasets)

## 0.6.1

- Fix dark mode (text fields no longer have white backgrounds)
- Performance improvements on the audio write path

## 0.6.0

- Add recording naming, renaming, and customizable file prefix

## 0.5.0

- Heal split sentences at speaker boundaries in diarization pipeline
- Add sentence-aware segment grouping to diarization merge pipeline
- Persist recording waveform across popover close/reopen

## 0.4.0

- Expose all FluidAudio diarization parameters in UI
- Remove device change listener from SystemAudioCapture
- Fix audio resource leak on quit and config change restart loop
- Print output file path before transcription starts

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
