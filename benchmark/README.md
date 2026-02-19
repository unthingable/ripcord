# Diarization Benchmark Suite

Measures diarization and speaker attribution accuracy against published datasets
with known ground truth. Reports Diarization Error Rate (DER) comparable to
published pyannote baselines.

## Quick Start

```bash
# Build the transcribe binary first
make build

# Run everything (download ~300MB, transcribe, score)
./benchmark.sh all --quick

# Or step by step:
./benchmark.sh download --quick   # ~300MB: 5 AMI meetings + 5 VoxConverse clips
./benchmark.sh prepare            # Convert AMI annotations to RTTM
./benchmark.sh run --quick        # Transcribe with ripcord
./benchmark.sh score              # Compute DER
```

## Modes

| Mode      | Data Size | AMI Meetings | VoxConverse Clips | Use Case                    |
|-----------|-----------|--------------|-------------------|-----------------------------|
| `--quick` | ~300 MB   | 5            | 5                 | Dev regression, fast CI     |
| `--full`  | ~1.2 GB   | 20 + IHM     | ~216              | Thorough evaluation, papers |

## Datasets

### AMI Meeting Corpus (Tier 1)

Meeting recordings with 3-5 speakers. CC BY 4.0 license.
Test split: ES2004, ES2014, IS1009, TS3003, TS3007 (standard scenario-only SC partition).

- **SDM** (headset mix): Single distant microphone — benchmarks our mono pipeline
- **IHM** (individual headsets): Per-speaker mics — enables Tier 2 channel-aware testing

pyannote community-1 baselines: SDM ~19.9% DER, IHM ~17.0% DER.

### VoxConverse v0.3 (Tier 1)

Multi-speaker YouTube clips (debates, news). CC BY 4.0 license.
Dev set: ~216 clips with RTTM ground truth.

pyannote community-1 baseline: ~11.2% DER.

## Tier 2: Channel-Aware Testing

Ripcord records stereo: L=system audio (remote speakers), R=mic (local speaker + bleed).
Currently this is naively averaged to mono before diarization.

The `--full` download includes AMI individual headset recordings. The `prepare`
step builds simulated stereo files:
- **L channel** = mix of all "remote" speakers' headsets
- **R channel** = one "local" speaker's headset

This lets us benchmark a future channel-aware pipeline that exploits the L/R
separation instead of discarding it.

## Directory Structure

```
benchmark/
  benchmark.sh              Main orchestrator
  lists/
    ami_test.txt            Full AMI test split (20 meetings)
    ami_quick.txt           Quick AMI subset (5 meetings)
    ami_ihm.txt             AMI meetings for IHM download (Tier 2)
    voxconverse_quick.txt   Quick VoxConverse subset (5 clips)
  scripts/
    download_ami.sh         AMI download script
    download_voxconverse.sh VoxConverse download script
    ami_to_rttm.py          Convert AMI NXT XML annotations to RTTM
    json_to_rttm.py         Convert ripcord JSON output to RTTM
    score.py                DER scoring (no external deps)
    ami_build_stereo.py     Build Tier 2 stereo test files from IHM
  data/                     Downloaded data (gitignored)
  results/                  Transcription output + scores (gitignored)
```

## Metrics

**DER (Diarization Error Rate)** = (missed + false alarm + confusion) / total reference speech

- **Missed speech**: Reference speech not covered by any system segment
- **False alarm**: System speech where reference has silence
- **Speaker confusion**: System and reference both have speech, but wrong speaker
- **Collar**: 250ms forgiveness window around reference boundaries (standard)

The scorer uses optimal speaker label mapping since our system produces
arbitrary labels (SPEAKER_00, etc.) while references use participant IDs.

## Overriding the Transcribe Binary

```bash
TRANSCRIBE_BIN=/path/to/transcribe ./benchmark.sh run
```
