import AVFoundation
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

    private func makeWAV(duration: Double = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPreprocessorRegression-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: Int(frames))
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
}
