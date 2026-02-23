# Changelog

## 0.7.1

- Fix rename text field not accepting spaces (was nested inside a Button)
- Auto-focus rename text field when entering rename mode
- Watch output directory for external changes and update recent recordings list

## 0.7.0

- Apply recording name as post-recording rename instead of baking into filename at start
- Tint menubar icon red while recording
- Add parameter sweep command for diarization tuning
- Add diarization benchmark suite with AMI and VoxConverse datasets
- Add compress command to transcode benchmark WAV files to M4A
- Make prepare command idempotent
- Fix stereo detection: check .m4a and .wav separately with OR logic
- Fix sweep output: print per-file progress with flush for parallel workers

## 0.6.1

- Fix dark mode: replace hardcoded white TextField backgrounds with system color
- Simplify expressions and deduplicate helpers across codebase
- Narrow JSON types from Codable to Encodable
- Optimize interleave buffer allocation on audio write path

## 0.6.0

- Add recording naming, renaming, and customizable file prefix
- Fix recording row layout: independent tooltips and popover anchoring
- Consolidate SRT/VTT timestamp formatters into a single function
- Use OutputFormat.allCases for transcript file detection

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
