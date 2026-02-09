import Foundation
import AVFoundation
import AudioToolbox

@main
struct E2ETestRunner {
    static func main() async {
        var passed = 0
        var failed = 0

        print("Starting E2E capture test...")

        do {
            // Test: Generate tone, capture, verify
            try await testSystemAudioCapture()
            passed += 1
            print("✓ System audio capture test passed")
        } catch {
            failed += 1
            print("✗ System audio capture test failed: \(error)")
            if let captureError = error as? CaptureTestError {
                switch captureError {
                case .permissionDenied:
                    print("  → This test requires System Audio Recording permission.")
                    print("  → Grant permission in System Settings > Privacy & Security > Screen & System Audio Recording")
                case .noSamplesCaptured:
                    print("  → No samples were captured. Ensure audio device is available.")
                case .zeroFilledBuffers:
                    print("  → Tap received callbacks but all audio data was zeros.")
                    print("  → macOS zero-fills tap buffers when the binary lacks permission.")
                    print("  → Grant 'Screen & System Audio Recording' to .build/test_e2e in:")
                    print("    System Settings > Privacy & Security > Screen & System Audio Recording")
                case .durationTooShort(let d):
                    print("  → Captured duration too short: \(d)s (expected >= 2.5s)")
                case .silenceDetected(let rms):
                    print("  → Captured audio is silence (RMS=\(rms)). Ensure test tone plays audibly.")
                }
            }
        }

        print("\n--- Test Summary ---")
        print("Passed: \(passed)")
        print("Failed: \(failed)")

        exit(failed == 0 ? 0 : 1)
    }

    static func testSystemAudioCapture() async throws {
        let tempDir = URL(fileURLWithPath: "/tmp/claude")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let testToneURL = tempDir.appendingPathComponent("test_tone_\(UUID().uuidString).wav")
        let capturedURL = tempDir.appendingPathComponent("captured_\(UUID().uuidString).wav")

        defer {
            try? FileManager.default.removeItem(at: testToneURL)
            try? FileManager.default.removeItem(at: capturedURL)
        }

        // Step 1: Generate 3s 1kHz test tone
        print("Generating 3s 1kHz test tone at \(testToneURL.path)...")
        try generateTestTone(url: testToneURL, frequency: 1000, duration: 3.0)

        // Step 2: Set up capture with thread-safe sample collection
        let capture = SystemAudioCapture()
        let capturedSamples = ThreadSafeFloatArray()

        capture.onSamples = { samples in
            capturedSamples.append(samples)
        }

        // Step 3: Start capture
        print("Starting SystemAudioCapture...")
        do {
            try await capture.start()
        } catch {
            throw CaptureTestError.permissionDenied
        }

        // Small delay to ensure capture is fully started
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Step 4: Play the test tone using afplay
        print("Playing test tone via afplay...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [testToneURL.path]

        try process.run()
        process.waitUntilExit()

        // Step 5: Wait for tail (500ms)
        print("Waiting for capture tail...")
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Step 6: Stop capture
        print("Stopping capture...")
        capture.stop()

        let samples = capturedSamples.getAll()
        let durationSec = Double(samples.count) / AudioConstants.sampleRate
        print("Captured \(samples.count) mono samples (\(durationSec) seconds)")

        guard !samples.isEmpty else {
            throw CaptureTestError.noSamplesCaptured
        }

        // Check for all-zeros (macOS delivers zero-filled buffers when permission is missing)
        let nonZeroCount = samples.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        print("Non-zero samples: \(nonZeroCount) / \(samples.count)")

        if nonZeroCount == 0 {
            throw CaptureTestError.zeroFilledBuffers
        }

        // Step 7: Convert mono to interleaved stereo and write
        print("Writing captured audio to \(capturedURL.path)...")
        let stereoSamples = monoToInterleavedStereo(mono: samples)

        let writer = AudioFileWriter(url: capturedURL, format: .wav, quality: .high)
        try writer.open()
        try writer.append(samples: stereoSamples)
        let info = try writer.finalize()

        print("Wrote \(info.duration)s, \(info.fileSize) bytes")

        // Step 8: Verify duration
        guard info.duration >= 2.5 else {
            throw CaptureTestError.durationTooShort(info.duration)
        }

        // Step 9: Verify non-silence (RMS check)
        let rms = calculateRMS(samples: samples)
        print("RMS level: \(rms)")

        guard rms > 0.001 else {
            throw CaptureTestError.silenceDetected(rms)
        }

        print("Verification passed: duration=\(info.duration)s, rms=\(rms)")
    }

    // Generate a mono sine wave test tone and write to WAV
    static func generateTestTone(url: URL, frequency: Double, duration: Double) throws {
        let sampleRate = AudioConstants.sampleRate
        let sampleCount = Int(sampleRate * duration)

        // Generate mono sine wave
        var monoSamples: [Float] = []
        monoSamples.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let sample = Float(sin(2.0 * .pi * frequency * t) * 0.5) // 0.5 amplitude
            monoSamples.append(sample)
        }

        // Convert to interleaved stereo for writing
        let stereoSamples = monoToInterleavedStereo(mono: monoSamples)

        // Write using AudioFileWriter
        let writer = AudioFileWriter(url: url, format: .wav, quality: .high)
        try writer.open()
        try writer.append(samples: stereoSamples)
        _ = try writer.finalize()
    }

    // Convert mono samples to interleaved stereo: [L, R, L, R, ...]
    // For this test: L=system audio, R=silence
    static func monoToInterleavedStereo(mono: [Float]) -> [Float] {
        var stereo: [Float] = []
        stereo.reserveCapacity(mono.count * 2)

        for sample in mono {
            stereo.append(sample)  // Left channel (system audio)
            stereo.append(0.0)     // Right channel (silence)
        }

        return stereo
    }

    // Calculate RMS (root mean square) to detect non-silence
    static func calculateRMS(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0.0 }

        let sumSquares = samples.reduce(0.0) { $0 + ($1 * $1) }
        return sqrt(sumSquares / Float(samples.count))
    }
}

// Thread-safe float array for collecting samples from callback
final class ThreadSafeFloatArray: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ newSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: newSamples)
    }

    func getAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

enum CaptureTestError: Error {
    case permissionDenied
    case noSamplesCaptured
    case zeroFilledBuffers
    case durationTooShort(Double)
    case silenceDetected(Float)
}
