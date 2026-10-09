import AVFoundation
import FluidAudio
import XCTest
@testable import TranscribeKit

final class AudioPreprocessorRegressionTests: XCTestCase {
    func testPrepareAudioRejectsNonIncreasingTrimRange() async throws {
        let source = try makeWAV()
        defer { try? FileManager.default.removeItem(at: source) }

        await assertInvalidRange(source: source, start: 0.5, end: 0.5)
        await assertInvalidRange(source: source, start: 0.8, end: 0.2)
    }

    func testPrepareAudioRejectsNonFiniteTrimRange() async throws {
        let source = try makeWAV()
        defer { try? FileManager.default.removeItem(at: source) }

        await assertInvalidRange(source: source, start: .infinity, end: 1)
        await assertInvalidRange(source: source, start: 0, end: .nan)
    }

    func testPrepareAudioTrimProducesTemporaryFileAndCleanupRemovesIt() async throws {
        let source = try makeWAV(duration: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        let result = try await AudioPreprocessor.prepareAudio(from: source, startTime: 0.2, endTime: 0.7)
        XCTAssertNotEqual(result.url, source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        let duration = await AudioPreprocessor.getAudioDuration(result.url)
        XCTAssertEqual(duration, 0.5, accuracy: 0.05)
        XCTAssertEqual(try peakAmplitude(of: result.url), 1, accuracy: 0.01)

        result.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.url.path))
    }

    func testPrepareAudioCanSelectASeparatedStereoChannel() async throws {
        let source = try makeStereoWAV()
        defer { try? FileManager.default.removeItem(at: source) }

        let system = try await AudioPreprocessor.prepareAudio(
            from: source, channel: 0, normalize: false)
        let result = try await AudioPreprocessor.prepareAudio(
            from: source, channel: 1, normalize: false)
        defer {
            system.cleanup()
            result.cleanup()
        }

        XCTAssertEqual(try meanAmplitude(of: system.url), 0.5, accuracy: 0.01)
        XCTAssertEqual(try meanAmplitude(of: result.url), -0.25, accuracy: 0.01)
    }

    func testSpeakerProfilesAreFilteredToFinalAssignments() {
        let result = DiarizationResult(
            segments: [
                TimedSpeakerSegment(
                    speakerId: "S1", embedding: [], startTimeSeconds: 0,
                    endTimeSeconds: 1, qualityScore: 1)
            ],
            speakerDatabase: ["S1": [1, 0], "S2": [0, 1]]
        )

        let cleaned = Transcriber.removingUnassignedSpeakerProfiles(from: result)

        XCTAssertEqual(Set(cleaned.speakerDatabase?.keys.map { $0 } ?? []), ["S1"])
    }

    func testNearIdenticalSpeakerProfilesAreMergedWithoutCollapsingDistinctProfiles() {
        let result = DiarizationResult(
            segments: [
                TimedSpeakerSegment(
                    speakerId: "S1", embedding: [], startTimeSeconds: 0,
                    endTimeSeconds: 1, qualityScore: 1),
                TimedSpeakerSegment(
                    speakerId: "S2", embedding: [], startTimeSeconds: 1,
                    endTimeSeconds: 3, qualityScore: 1),
                TimedSpeakerSegment(
                    speakerId: "S3", embedding: [], startTimeSeconds: 3,
                    endTimeSeconds: 4, qualityScore: 1)
            ],
            speakerDatabase: [
                "S1": [1, 0],
                "S2": [0.999, 0.02],
                "S3": [0, 1]
            ]
        )

        let merged = Transcriber.mergingNearDuplicateSpeakerProfiles(from: result)

        XCTAssertEqual(merged.segments.map(\.speakerId), ["S2", "S2", "S3"])
        XCTAssertEqual(Set(merged.speakerDatabase?.keys.map { $0 } ?? []), ["S2", "S3"])
    }

    func testSeparatedChannelDiarizationIsLimitedToOfflineEngine() {
        XCTAssertTrue(Transcriber.shouldUseSplitChannelDiarization(
            channelsAreSeparated: true, engine: .offline))
        XCTAssertFalse(Transcriber.shouldUseSplitChannelDiarization(
            channelsAreSeparated: true, engine: .lseend))
        XCTAssertFalse(Transcriber.shouldUseSplitChannelDiarization(
            channelsAreSeparated: true, engine: .sortformer))
        XCTAssertFalse(Transcriber.shouldUseSplitChannelDiarization(
            channelsAreSeparated: false, engine: .offline))
    }

    func testNoSpeechFallbackRequiresAValidMicrophoneResult() {
        let microphone = diarizationResult(speaker: "S1")

        XCTAssertTrue(Transcriber.shouldUseMicrophoneOnlyFallback(
            for: OfflineDiarizationError.noSpeechDetected,
            microphoneResult: microphone))
        XCTAssertFalse(Transcriber.shouldUseMicrophoneOnlyFallback(
            for: OfflineDiarizationError.noSpeechDetected,
            microphoneResult: nil))
        XCTAssertFalse(Transcriber.shouldUseMicrophoneOnlyFallback(
            for: OfflineDiarizationError.noSpeechDetected,
            microphoneResult: diarizationResult(segments: [])))
        XCTAssertFalse(Transcriber.shouldUseMicrophoneOnlyFallback(
            for: OfflineDiarizationError.processingFailed("test"),
            microphoneResult: microphone))
    }

    func testSplitChannelCombinationKeepsMicrophoneWhenSystemHasNoSpeech() {
        let microphone = diarizationResult(speaker: "S1")

        let combined = Transcriber.combineSplitChannelResults(
            system: nil,
            microphone: microphone)

        XCTAssertEqual(combined.segments.map(\.speakerId), ["LOCAL"])
        XCTAssertEqual(combined.speakerDatabase?["LOCAL"], [1, 0])
    }

    func testMeaningfulSignalCheckSkipsSilence() async throws {
        let silence = try makeWAV(amplitude: 0)
        let speech = try makeWAV(amplitude: 0.05)
        defer {
            try? FileManager.default.removeItem(at: silence)
            try? FileManager.default.removeItem(at: speech)
        }

        let silenceHasSignal = try await AudioPreprocessor.hasMeaningfulSignal(in: silence)
        let speechHasSignal = try await AudioPreprocessor.hasMeaningfulSignal(in: speech)
        XCTAssertFalse(silenceHasSignal)
        XCTAssertTrue(speechHasSignal)
    }

    private func assertInvalidRange(source: URL, start: Double, end: Double) async {
        do {
            _ = try await AudioPreprocessor.prepareAudio(from: source, startTime: start, endTime: end)
            XCTFail("Expected invalid time range")
        } catch let error as AudioPreprocessorError {
            guard case .invalidTimeRange = error else {
                return XCTFail("Expected invalid time range, got \(error)")
            }
        } catch {
            XCTFail("Expected AudioPreprocessorError.invalidTimeRange, got \(error)")
        }
    }

    private func makeWAV(duration: Double = 1, amplitude: Float = 0.25) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPreprocessorRegression-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: amplitude, count: Int(frames))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func diarizationResult(
        speaker: String = "S1",
        segments: [TimedSpeakerSegment]? = nil
    ) -> DiarizationResult {
        DiarizationResult(
            segments: segments ?? [
                TimedSpeakerSegment(
                    speakerId: speaker, embedding: [1, 0], startTimeSeconds: 0,
                    endTimeSeconds: 1, qualityScore: 1)
            ],
            speakerDatabase: [speaker: [1, 0]]
        )
    }

    private func makeStereoWAV(duration: Double = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPreprocessorStereoRegression-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)!
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: 0.5, count: Int(frames))
        buffer.floatChannelData![1].initialize(repeating: -0.25, count: Int(frames))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func peakAmplitude(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(file.processingFormat.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        return peak
    }

    private func meanAmplitude(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return 0 }
        let channel = channels[0]
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var total: Float = 0
        for frame in 0..<count { total += channel[frame] }
        return total / Float(count)
    }
}
