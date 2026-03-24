# Mic Hogging Investigation

## Problem

Ripcord blocks meeting apps (Chrome/Teams/Zoom) from using the microphone. User must kill Ripcord to join meetings. After killing, mic doesn't work in the meeting until rejoin (Chrome doesn't re-enumerate devices).

## Timeline

- **Feb 23-26**: Problem discovered. Attributed to IOState [2,0] from two input sessions (mic AUHAL + system capture aggregate device).
- **Mar 19**: Fix 1 (0b58f4e): Coordinated cycling — stop mic AUHAL before system capture restarts so IOState goes through [0,0] instead of spiking to [2,0].
- **Mar 23**: Fix 2 (4868fdf): Suppress mic's independent restart during coordinated cycle to avoid re-introducing a race.
- **Mar 24**: Bug recurs despite both fixes. Deep investigation begins.

## Mar 24 Investigation

### Log evidence

AirPods reconnected. Coordinated restart completed cleanly:
```
12:00:44.745  Output device changed, scheduling recycle
12:00:44.745  Mic restart suppressed (system capture coordinating)
12:00:47.067  System capture restarted after route change
12:00:47.072  Mic restarts on Device 187, AirPods HFP (24kHz)
```

40 seconds later, Chrome's VPIO fails in steady state:
```
12:01:27.287  Initialize failed - thread hasBeenStopped: 1 and shouldExit: 1
12:01:41.439  Initialize failed - thread hasBeenStopped: 1  (retry ~14s)
12:01:55.588  Initialize failed - thread hasBeenStopped: 1  (retry ~14s)
```

Preceded by: `StartIOThread: got an error from starting the IO thread, Error: 0x3C` (ETIMEDOUT).

This is steady-state blocking, not a restart race. The coordinated cycling fixes were irrelevant to the primary bug.

### Research

- Chrome uses VoiceProcessingIO (VPIO) for WebRTC calls. VPIO creates an internal private aggregate device for echo cancellation.
- A single AUHAL does NOT block VPIO — proven by Chrome, OBS, Audacity, QuickTime all coexisting with meeting app VPIO.
- The problem is Ripcord's system capture aggregate device with tap-only input streams (no physical input sub-devices).

### VocalIsolationType error

```
HALS_MetaDevice::SetPropertyData: Device does not have non-tap input streams
for kAudioDevicePropertyVocalIsolationType
```

macOS Voice Isolation tries to apply to the tap-only aggregate and throws exceptions that disrupt meeting app audio initialization.

### Verification tests

- **Run A** (mic AUHAL only, no system capture): Chrome VPIO works, zero errors.
- **Run B** (both sessions, fresh launch): Transient errors but Chrome eventually works.
- **Run B after AirPods reconnect**: Permanent "Initialize failed" loop — the real bug.
- **Teardown logging**: All destroy calls succeed — no orphaned resources.
- **Aggregate device properties**: Identical between fresh launch and post-reconnect.

## Approaches Explored and Rejected

1. **ScreenCaptureKit**: Kills spatial audio on AirPods (dealbreaker). Also has reliability issues and requires more invasive Screen Recording permission.

2. **AudioServerPlugin (virtual output device)**: Correct long-term approach for always-on system audio capture without device graph pollution. Plugin creates virtual output device, interposes in audio chain, copies audio transparently. However: plugins cannot use process tap APIs (client-side only, sandboxed). Would need to implement audio interposition from scratch — significant effort. Still a viable future direction if process tap API limitations prove insurmountable.

3. **kAudioDevicePropertyDeviceCanBeDefaultDevice=false**: Property is read-only on aggregate devices (error 'nset').

4. **Lazy-start aggregate** (only during recording): Loses retroactive system audio buffer — unacceptable.

## Root Cause and Fix

**Root cause**: `kAudioAggregateDeviceTapAutoStartKey: true` on the system capture aggregate device. With `autoStart=true`, the aggregate device registers differently in coreaudiod's device graph, causing Voice Isolation and VPIO to interact with it adversely. VocalIsolationType exceptions disrupt VPIO initialization, especially after device changes (AirPods reconnect).

**Fix**: Set `kAudioAggregateDeviceTapAutoStartKey: false`. All other open-source process tap implementations use `false` or omit this key entirely. With `autoStart=false`, the aggregate still captures audio (we call `AudioDeviceStart` manually), but it no longer triggers VocalIsolationType exceptions or VPIO initialization failures.

**Verification** (after AirPods reconnect with `autoStart=false`):
- Zero "Initialize failed" errors (previously repeated every 14s)
- Zero VocalIsolationType exceptions
- Zero mIODisableCount errors
- Chrome `getUserMedia` succeeds ("MIC OK")

## Future Direction: Virtual Output Device (AudioServerPlugin)

If the process tap API proves insufficient long-term, the architectural alternative is an AudioServerPlugin that creates a virtual output device (like BackgroundMusic or Rogue Amoeba's ACE engine):

- Plugin creates virtual output device, sets as default output
- Audio flows: apps -> virtual device -> plugin copies audio -> real output device
- No process tap, no aggregate device, no device graph pollution
- Plugin runs inside coreaudiod, transparent to all apps
- Plugin CANNOT use process tap APIs (client-side only, plugin sandboxed)
- Significant implementation effort (HAL plugin API, real-time constraints, system deployment)
- Reference implementations: BlackHole (loopback), BackgroundMusic (interposition), libASPL (framework)
- Deployment: `.driver` bundle in `/Library/Audio/Plug-Ins/HAL/`

## References

- Apple TN2091: Device input using HAL Output Audio Unit
- WWDC 2023: What's new in voice processing
- Apple Developer Forums thread/751100: Voice Processing in multiple apps
- Chromium `audio_low_latency_input_mac.cc`: Chrome's AUHAL usage
- OBS `mac-audio.c`: OBS's AUHAL usage
- Mozilla Bug 1869526: VoiceProcessingIO in cubeb
