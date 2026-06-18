# Changelog

## [0.12.1] - 2026-06-18

### Fixed
  * Make hover affordances visible on compact recording setting labels in the main panel.

## [0.12.0] - 2026-06-17

### Added
  * Per-device USB input controls for channel selection and input gain, including mono channel picking for multi-channel devices.
  * Voice Isolation detection with a warning and quick access to the macOS Mic Mode picker when recording.
  * Compact, clickable recording settings in the main panel for buffer duration, file format, and quality.
  * Diarization accuracy test harness and speaker re-verification pass for improving speaker attribution.
  * Generic CoreAudio USB capture diagnostic target for isolating USB device behavior.

### Changed
  * Reworked microphone capture around AUHAL with an IOProc fallback, lower-latency sample handoff, and safer real-time callback behavior.
  * Preserve incoming stereo system audio in mixed recordings, and downmix sources only when writing split-channel recording files.
  * Skip automatic live transcript and post-recording transcription for USB inputs that look like instruments or audio interfaces.
  * Replace the expected speaker count dropdown with compact quick-pick buttons.
  * Raise the default diarization minimum segment duration from 0.1s to 0.5s.

### Fixed
  * Fix USB instrument capture reliability for class-compliant USB audio interfaces, with a warning when macOS Voice Isolation may still suppress non-voice input.
  * Fix stereo-mode recordings becoming dual-mono because system audio capture was created as mono.
  * Fix per-device dB gain editing so partially typed values are not immediately overwritten.
  * Fix speaker preview playback when all candidate segments are short.
  * Clamp invalid or out-of-range samples before writing audio files.

## 0.11.0

- Fix recording appearing to stop on its own during a meeting. A live transcript error was overwriting the recording state, making the UI show "not recording" while audio continued writing to disk — but the file couldn't be finalized cleanly.
- Fix potential crash when system audio capture teardown races with a device-change restart. Both paths could destroy the same CoreAudio objects simultaneously. Teardown is now serialized with a lock.
- Fix silent audio loss when pausing a recording on a full disk. Write errors during the pause flush were swallowed instead of being reported when the recording stopped.
- Handle SIGTERM/SIGINT to finalize recordings before exit, so killing the process no longer produces corrupt M4A files with missing headers.
- Fix potential deadlock in transcript socket broadcast when cleaning up disconnected clients.

## 0.10.1

- Prompt to download transcription models on first launch instead of requiring users to find the option in Settings.
- Show model download button in the main panel when models aren't installed, so it's clear why transcription is unavailable.
- Auto-enable transcription after downloading models for the first time.
- Fix Settings window appearing behind the menubar panel.
- Fix recent recordings not appearing on fresh install. The recordings directory wasn't created until the first recording, so the file listing and directory monitor both silently failed.
- Show version number in Settings.
- Add install/update script (`install.sh`) for unsigned builds.

## 0.10.0

- **Live transcript** — real-time streaming transcription displayed in a dedicated window. Uses sliding-window ASR with tunable chunk size, lookahead, and confirmation threshold. Includes hypothesis (in-progress) word display that updates as speech is recognized.
- **Remote control socket** — Unix domain socket at `/tmp/ripcord-transcript.sock` for external tools to receive live transcript JSONL and send commands. Supports replay-on-connect so late joiners get recent history.
- **Video file transcription** — transcribe audio from video files (MP4, MOV, AVI) in addition to audio formats.
- **Speaker identity persistence** — speaker voice profiles are saved across transcriptions. When a known speaker appears in a new recording, they're automatically matched. New speakers get similarity-ranked name suggestions from existing profiles.
- **Appearance theme override** — choose between System, Light, and Dark themes in Settings.
- Fix mic capture blocking meeting apps (Zoom, Teams, etc.) from initializing their audio pipeline. The system capture aggregate device was triggering Voice Isolation exceptions in VPIO — resolved by disabling auto-start on the aggregate.
- Fix live transcript window not reconnecting when the stream is toggled off and back on.
- Fix data race in live transcript where system and mic consumer tasks could corrupt shared state.
- Fix socket server closing file descriptors before cancelling their read sources, risking use-after-close on recycled FDs.
- Fix speaker name suggestion dropdown staying open after selecting a name.
- Fix popover panels (speaker naming, transcription config) being translucent when the main window is opaque.
- Fix live transcript toggle being disabled during file transcription — it uses independent ASR instances and doesn't conflict.

## 0.9.1

- Fix mic capture blocking other apps' audio negotiation. CoreAudio listeners now run on dedicated serial queues with debouncing, so events like AirPods connecting during a Zoom call produce a single clean restart instead of cascading teardown loops.
- Fix transcribe buttons vanishing while a transcription is in progress — they now stay visible but disabled.
- Cancel an in-progress transcription by hovering the progress spinner to reveal a stop button.

## 0.9.0

- Pause and resume during recording. Press Pause to suspend capture without ending the session — the waveform keeps rolling and new bars turn orange to show the gap. Resume picks up where you left off. Cmd+Shift+O cycles between recording and paused; Cmd+. stops from either state.
- Continuous waveform that never resets. The rolling 100-bar display stays live across all states — buffering, recording, paused, and after stopping. Bars are color-coded: blue for the capture window, red for recorded audio, orange for paused sections, and dimmed red/orange for prior recordings as they scroll off.
- Lower the minimum capture lookback from 30 seconds to 5 seconds

## 0.8.1

- Fix stereo and mic toggles being vertically misaligned in the mic row

## 0.8.0

- True stereo recording: split system audio into the left channel and mic into the right, so you can isolate or remix sources after the fact. Toggle between split and mixed modes from the mic row or Settings.
- Stereo icon lights up blue/green when both channels are actively recording, and level meters always show two bars to reflect the current mode

## 0.7.5

- Fix new recording appearing with the previous recording's metadata. The directory monitor was racing with recording finalization — inserting a stale entry before the file was fully written.

## 0.7.4

- Fix Zoom (and similar apps) causing a beachball and mic indicator flashing when joining a meeting. Ripcord was restarting its audio capture too aggressively during other apps' audio negotiation — concurrent CoreAudio operations were contending on a system-wide lock.

## 0.7.3

- Rewrite audio capture pipeline for improved stability
- Fix microphone capture failing on AirPods and other Bluetooth headsets
- Improve audio stability when switching devices during a session

## 0.7.2

- Fix microphone access flickering on audio device changes (e.g. plugging in headphones)

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
