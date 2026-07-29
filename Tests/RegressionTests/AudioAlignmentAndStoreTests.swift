import CoreAudio
import AVFoundation
import Foundation
import TranscribeKit
import XCTest
@testable import Ripcord

final class AudioAlignmentAndStoreTests: XCTestCase {
    func testTimelineAlignerMixesStereoChannelsAtSharedTimeline() {
        let aligner = AudioTimelineAligner()
        let output = aligner.append(
            system: [chunk(startFrame: 1_000, samples: [1, 2, 3, 4])],
            mic: [chunk(startFrame: 1_000, samples: [10, 20, 30, 40])],
            micAdvanceFrames: 0,
            split: false,
            force: false
        )

        XCTAssertEqual(output, [11, 22, 33, 44])
    }

    func testTimelineAlignerSplitProducesMonoSystemAndMicChannels() {
        let aligner = AudioTimelineAligner()
        let output = aligner.append(
            system: [chunk(startFrame: 1_000, samples: [2, 4, 6, 8])],
            mic: [chunk(startFrame: 1_000, samples: [10, 14, 20, 24])],
            micAdvanceFrames: 0,
            split: true,
            force: false
        )

        XCTAssertEqual(output, [3, 12, 7, 22])
    }

    func testTimelineAlignerUsesLatencyAdvanceToAlignMic() {
        let aligner = AudioTimelineAligner()
        let output = aligner.append(
            system: [chunk(startFrame: 1_000, samples: [1, 1, 2, 2])],
            mic: [chunk(startFrame: 1_001, samples: [10, 10, 20, 20])],
            micAdvanceFrames: 1,
            split: false,
            force: false
        )

        XCTAssertEqual(output, [11, 11, 22, 22])
    }

    func testTimelineAlignerPrimeBridgesBufferedAndLiveAudio() {
        let aligner = AudioTimelineAligner()
        aligner.prime(
            system: [chunk(startFrame: 1_000, samples: [1, 1])],
            mic: [],
            micAdvanceFrames: 1
        )

        let output = aligner.append(
            system: [chunk(startFrame: 1_001, samples: [2, 2])],
            mic: [chunk(startFrame: 1_001, samples: [10, 10, 20, 20])],
            micAdvanceFrames: 1,
            split: false,
            force: false
        )

        XCTAssertEqual(output, [11, 11, 22, 22])
    }

    func testTimestampedHandoffPreservesSamplesAndTiming() {
        let handoff = AudioChunkHandoff(capacityFrames: 8)
        let source = chunk(startFrame: 2_000, samples: [1, 2, 3, 4])
        source.samples.withUnsafeBufferPointer {
            handoff.write($0, timing: source.timing)
        }

        let drained = handoff.drain()
        XCTAssertEqual(drained.droppedSamples, 0)
        XCTAssertEqual(drained.chunks.count, 1)
        XCTAssertEqual(drained.chunks[0].samples, source.samples)
        XCTAssertEqual(drained.chunks[0].startFrame, source.startFrame)
    }

    func testCircularBufferSnapshotsSamplesWithTheirEndpoint() {
        let buffer = CircularAudioBuffer(durationSeconds: 1, sampleRate: 8)
        let samples: [Float] = [1, 2, 3, 4]
        let endpoint = AudioConvertNanosToHostTime(2_000_000_000)
        samples.withUnsafeBufferPointer { buffer.write($0, endHostTime: endpoint) }

        let snapshot = buffer.readWithEndHostTime(lastNFrames: 2)
        XCTAssertEqual(snapshot.samples, samples)
        XCTAssertEqual(snapshot.endHostTime, endpoint)
    }

    func testCircularBufferUsesAbsoluteHalfOpenCaptureRanges() {
        let buffer = CircularAudioBuffer(durationSeconds: 1, sampleRate: 4)
        [Float](repeating: 1, count: 4).withUnsafeBufferPointer {
            buffer.write($0, startFrame: 100)
        }
        [Float](repeating: 2, count: 4).withUnsafeBufferPointer {
            buffer.write($0, startFrame: 102)
        }
        [Float](repeating: 3, count: 4).withUnsafeBufferPointer {
            buffer.write($0, startFrame: 104)
        }

        XCTAssertEqual(buffer.visibleRange, CaptureFrameRange(102, 106))
        let snapshot = buffer.snapshot(range: CaptureFrameRange(101, 105))
        XCTAssertEqual(snapshot.range, CaptureFrameRange(102, 105))
        XCTAssertEqual(snapshot.samples, [2, 2, 2, 2, 3, 3])
    }

    func testCircularBufferRepresentsForwardTimestampGapAsSilence() {
        let buffer = CircularAudioBuffer(durationSeconds: 1, sampleRate: 6)
        [Float](repeating: 1, count: 2).withUnsafeBufferPointer {
            buffer.write($0, startFrame: 10)
        }
        [Float](repeating: 2, count: 2).withUnsafeBufferPointer {
            buffer.write($0, startFrame: 13)
        }

        XCTAssertEqual(buffer.visibleRange, CaptureFrameRange(10, 14))
        XCTAssertEqual(buffer.snapshot().samples, [1, 1, 0, 0, 0, 0, 2, 2])
    }

    func testCircularBufferTrimsOverlappingTimestampedChunk() {
        let buffer = CircularAudioBuffer(durationSeconds: 1, sampleRate: 6)
        [Float](arrayLiteral: 1, 1, 2, 2).withUnsafeBufferPointer {
            buffer.write($0, startFrame: 10)
        }
        [Float](arrayLiteral: 9, 9, 3, 3).withUnsafeBufferPointer {
            buffer.write($0, startFrame: 11)
        }

        XCTAssertEqual(buffer.visibleRange, CaptureFrameRange(10, 13))
        XCTAssertEqual(buffer.snapshot().samples, [1, 1, 2, 2, 3, 3])
    }

    func testCircularBufferRebasesAcrossTimestampDiscontinuities() {
        let buffer = CircularAudioBuffer(durationSeconds: 1, sampleRate: 4)
        [Float](repeating: 1, count: 2).withUnsafeBufferPointer {
            buffer.write($0, startFrame: 10, endHostTime: 123)
        }
        [Float](repeating: 2, count: 2).withUnsafeBufferPointer {
            buffer.write($0, startFrame: 100)
        }
        XCTAssertEqual(buffer.visibleRange, CaptureFrameRange(100, 101))
        XCTAssertEqual(buffer.snapshot().samples, [2, 2])
        XCTAssertNil(buffer.readWithEndHostTime(lastNFrames: 1).endHostTime)

        [Float](repeating: 3, count: 2).withUnsafeBufferPointer {
            buffer.write($0, startFrame: 0)
        }
        XCTAssertEqual(buffer.visibleRange, CaptureFrameRange(0, 1))
        XCTAssertEqual(buffer.snapshot().samples, [3, 3])
    }

    func testOverallTranscriptionProgressDoesNotResetBetweenPhases() {
        let start = Date(timeIntervalSince1970: 1_000)
        let phases: [TranscriptionPhase] = [
            .preparing, .transcribing, .diarizing, .finalizing
        ]
        var estimate = TranscriptionProgressEstimate(
            phases: phases,
            expectedDurations: [
                TranscriptionPhase.preparing.rawValue: 10,
                TranscriptionPhase.transcribing.rawValue: 40,
                TranscriptionPhase.diarizing.rawValue: 30,
                TranscriptionPhase.finalizing.rawValue: 5
            ],
            startedAt: start
        )

        _ = estimate.update(
            phase: .transcribing,
            reportedProgress: 0.5,
            at: start.addingTimeInterval(10)
        )
        let transcription = estimate.snapshot(at: start.addingTimeInterval(30))
        _ = estimate.update(
            phase: .diarizing,
            reportedProgress: nil,
            at: start.addingTimeInterval(50)
        )
        let diarizationStart = estimate.snapshot(at: start.addingTimeInterval(50))
        let diarizationLater = estimate.snapshot(at: start.addingTimeInterval(60))

        XCTAssertGreaterThan(diarizationStart.fraction, transcription.fraction)
        XCTAssertGreaterThan(diarizationLater.fraction, diarizationStart.fraction)
        XCTAssertLessThan(diarizationLater.fraction, 1)
        XCTAssertNotNil(diarizationLater.estimatedRemaining)
    }

    func testTranscriptionTimingStoreLearnsCompletedPhaseRate() {
        let suiteName = "TranscriptionTimingStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TranscriptionTimingStore(defaults: defaults, storageKey: "timings")

        store.record(
            [CompletedTranscriptionPhase(phase: TranscriptionPhase.diarizing.rawValue, duration: 50)],
            profile: "v3.offline.balanced",
            audioDuration: 100
        )
        let estimates = store.expectedDurations(
            profile: "v3.offline.balanced",
            audioDuration: 200,
            phases: [.diarizing],
            diarizationEngine: .offline
        )

        XCTAssertEqual(estimates[TranscriptionPhase.diarizing.rawValue], 100)
    }

    func testPauseSelectionExcludesGapAndNeverDuplicatesTrimmedTail() {
        var timeline = RecordingSelectionTimeline()
        timeline.start(with: CaptureFrameRange(0, 100))
        timeline.pause(at: 100)
        timeline.updatePause(
            out: 80,
            in: 150,
            now: 200,
            visible: CaptureFrameRange(0, 200)
        )

        XCTAssertEqual(
            timeline.selectedRanges(at: 200),
            [CaptureFrameRange(0, 80), CaptureFrameRange(150, 200)]
        )
        XCTAssertEqual(
            timeline.selectedSlices(from: 50, to: 175, at: 200),
            [CaptureFrameRange(50, 80), CaptureFrameRange(150, 175)]
        )

        timeline.resume(at: 200)
        timeline.extendLive(to: 250)
        timeline.stop(at: 250)
        XCTAssertEqual(
            timeline.selectedRanges(at: 250),
            [CaptureFrameRange(0, 80), CaptureFrameRange(150, 250)]
        )
    }

    func testStopWhilePausedResolvesPickupThroughStopFrame() {
        var timeline = RecordingSelectionTimeline()
        timeline.start(with: CaptureFrameRange(0, 100))
        timeline.pause(at: 100)
        timeline.updatePause(
            out: 90,
            in: 140,
            now: 180,
            visible: CaptureFrameRange(0, 180)
        )
        timeline.stop(at: 220)

        XCTAssertEqual(
            timeline.selectedRanges(at: 220),
            [CaptureFrameRange(0, 90), CaptureFrameRange(140, 220)]
        )
    }

    func testMultiplePauseEditsProduceOrderedDisjointRanges() {
        var timeline = RecordingSelectionTimeline()
        timeline.start(with: CaptureFrameRange(0, 100))
        timeline.pause(at: 100)
        timeline.updatePause(
            out: 90,
            in: 150,
            now: 200,
            visible: CaptureFrameRange(0, 200)
        )
        timeline.resume(at: 200)
        timeline.extendLive(to: 250)
        timeline.pause(at: 250)
        timeline.updatePause(
            out: 240,
            in: 300,
            now: 320,
            visible: CaptureFrameRange(0, 320)
        )
        timeline.stop(at: 350)

        XCTAssertEqual(
            timeline.selectedRanges(at: 350),
            [
                CaptureFrameRange(0, 90),
                CaptureFrameRange(150, 240),
                CaptureFrameRange(300, 350),
            ]
        )
        XCTAssertEqual(
            timeline.outputSpans(at: 350).map(\.outputStart),
            [0, 90, 180]
        )
    }

    func testPinnedInFollowsNowWithoutBackfillingUntilMoved() {
        var timeline = RecordingSelectionTimeline()
        timeline.start(with: CaptureFrameRange(0, 100))
        timeline.pause(at: 100)
        timeline.advancePaused(to: 200)

        XCTAssertEqual(
            timeline.selectedRanges(at: 200),
            [CaptureFrameRange(0, 100)]
        )
        XCTAssertEqual(timeline.pauseEdit?.in, 200)
    }

    func testFinalizedEditPlanComposesFrozenExtensionsAndEDLCrop() {
        let descriptor = descriptor(
            spans: [
                SourceOutputSpan(source: CaptureFrameRange(100, 150), outputStart: 0),
                SourceOutputSpan(source: CaptureFrameRange(200, 250), outputStart: 50),
            ]
        )
        let plan = FinalizedBoundaryEditPlan(
            selection: CaptureFrameRange(50, 260),
            descriptor: descriptor
        )

        XCTAssertEqual(plan.prefixRange, CaptureFrameRange(50, 100))
        XCTAssertEqual(plan.suffixRange, CaptureFrameRange(250, 260))
        XCTAssertEqual(plan.originalCrop, 0...(100 / AudioConstants.sampleRate))
    }

    func testFinalizedEditPlanMapsAcrossExcludedPauseGap() {
        let descriptor = descriptor(
            spans: [
                SourceOutputSpan(source: CaptureFrameRange(100, 150), outputStart: 0),
                SourceOutputSpan(source: CaptureFrameRange(200, 250), outputStart: 50),
            ]
        )
        let plan = FinalizedBoundaryEditPlan(
            selection: CaptureFrameRange(125, 225),
            descriptor: descriptor
        )

        XCTAssertNil(plan.prefixRange)
        XCTAssertNil(plan.suffixRange)
        XCTAssertEqual(
            plan.originalCrop,
            (25 / AudioConstants.sampleRate)...(75 / AudioConstants.sampleRate)
        )
    }

    func testAudioEditRendererComposesPrefixCropAndSuffixForBothFormats() throws {
        for format in AudioOutputFormat.allCases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RipcordEditRenderer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("source.\(format.fileExtension)")
            let staging = directory.appendingPathComponent("staging.\(format.fileExtension)")
            let sourceWriter = AudioFileWriter(url: source, format: format, quality: .medium)
            try sourceWriter.open()
            try sourceWriter.append(samples: [Float](repeating: 0.25, count: 48_000 * 2))
            _ = try sourceWriter.finalize()

            let extensionFrames = 4_800
            let info = try AudioEditRenderer.render(
                from: source,
                originalCrop: 0.25...0.75,
                prefix: [Float](repeating: 0.1, count: extensionFrames * 2),
                suffix: [Float](repeating: 0.2, count: extensionFrames * 2),
                to: staging,
                format: format,
                quality: .medium
            )

            XCTAssertEqual(info.duration, 0.7, accuracy: 0.03)
            XCTAssertGreaterThan(info.fileSize, 0)
            XCTAssertNoThrow(try AVAudioFile(forReading: staging))
        }
    }

    func testMicLatencyStoreClampsAndPersistsSettings() {
        let suiteName = "MicLatencyStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MicLatencyStore(key: "settings", defaults: defaults)

        store.setSettings(MicLatencySettings(autoEnabled: true, manualOffsetMs: 400, manualTrimMs: -400), forUID: "mic")

        XCTAssertEqual(store.settings(forUID: "mic"), MicLatencySettings(autoEnabled: true, manualOffsetMs: 250, manualTrimMs: -250))
        XCTAssertEqual(store.allSettings()["mic"]?.manualOffsetMs, 250)
    }

    func testMicGainStoreClampsAndConvertsDecibels() {
        let suiteName = "MicGainStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MicGainStore(key: "gain", defaults: defaults)

        store.setGainDB(100, forUID: "mic")
        XCTAssertEqual(store.gainDB(forUID: "mic"), 80)
        XCTAssertEqual(MicGainStore.linearMultiplier(forDB: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(MicGainStore.linearMultiplier(forDB: 20), 10, accuracy: 0.0001)
    }

    private func chunk(startFrame: Int64, samples: [Float]) -> AudioSampleChunk {
        let hostTime = AudioConvertNanosToHostTime(
            UInt64(Double(startFrame) * 1_000_000_000 / AudioConstants.sampleRate)
        )
        return AudioSampleChunk(
            samples: samples,
            timing: AudioSampleTiming(hostTime: hostTime, sampleTime: Double(startFrame), sampleRate: AudioConstants.sampleRate, channelsPerFrame: 2)
        )
    }

    private func descriptor(spans: [SourceOutputSpan]) -> FinalizedRecordingDescriptor {
        FinalizedRecordingDescriptor(
            recording: RecordingInfo(
                url: URL(fileURLWithPath: "/tmp/test.wav"),
                duration: Double(spans.last?.outputEnd ?? 0) / AudioConstants.sampleRate,
                fileSize: 1
            ),
            spans: spans,
            split: true,
            format: .wav,
            quality: .medium,
            micAdvanceFrames: 0,
            fingerprint: .init(size: 1, modificationDate: Date(timeIntervalSince1970: 0))
        )
    }
}
