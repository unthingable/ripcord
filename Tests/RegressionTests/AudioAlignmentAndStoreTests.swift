import CoreAudio
import Foundation
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
}
