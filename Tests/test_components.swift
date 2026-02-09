// Standalone tests for Ripcord components.
// Build & run:  make test

import Foundation
import AVFoundation
import AudioToolbox

// ── Minimal test harness ──

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL [\(file):\(line)] \(msg)")
    }
}

func assertThrows<T>(_ expr: @autoclosure () throws -> T, _ msg: String, file: String = #file, line: Int = #line) {
    do {
        _ = try expr()
        failed += 1
        print("FAIL [\(file):\(line)] \(msg) — expected throw, got success")
    } catch {
        passed += 1
    }
}

// ── Helpers ──

func sineWave(seconds: Double, sampleRate: Int = 48000, frequency: Double = 440) -> [Float] {
    let count = Int(seconds * Double(sampleRate))
    return (0..<count).map { Float(sin(Double($0) * 2 * .pi * frequency / Double(sampleRate))) }
}

/// Generates interleaved stereo: sine on L, cosine on R.
func stereoSineWave(seconds: Double, sampleRate: Int = 48000, frequency: Double = 440) -> [Float] {
    let frames = Int(seconds * Double(sampleRate))
    var result = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let phase = Double(i) * 2 * .pi * frequency / Double(sampleRate)
        result[i * 2]     = Float(sin(phase))  // L
        result[i * 2 + 1] = Float(cos(phase))  // R
    }
    return result
}

/// Local copy of interleave for testing (RecordingManager can't compile in test target).
func interleave(_ system: [Float], _ mic: [Float]) -> [Float] {
    let len = max(system.count, mic.count)
    guard len > 0 else { return [] }
    var result = [Float](repeating: 0, count: len * 2)
    for i in 0..<len {
        result[i * 2]     = i < system.count ? system[i] : 0
        result[i * 2 + 1] = i < mic.count    ? mic[i]    : 0
    }
    return result
}

// ═══════════════════════════════════════════════════════════════
// CircularAudioBuffer tests
// ═══════════════════════════════════════════════════════════════

func testBufferBasicWriteAndDrain() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 10) // capacity = 10
    buf.write([1, 2, 3])
    assert(buf.sampleCount == 3, "sampleCount should be 3")

    let drained = buf.drain()
    assert(drained == [1, 2, 3], "drain should return [1,2,3], got \(drained)")
    assert(buf.sampleCount == 0, "sampleCount should be 0 after drain")
}

func testBufferDrainEmpty() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 10)
    let drained = buf.drain()
    assert(drained.isEmpty, "drain on empty buffer should return []")
}

func testBufferWrapAround() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 5) // capacity = 5
    buf.write([1, 2, 3, 4, 5]) // fill to capacity
    buf.write([6, 7])           // overwrite oldest (1, 2)

    let drained = buf.drain()
    // Oldest data is 3,4,5 then 6,7
    assert(drained == [3, 4, 5, 6, 7], "wrap-around drain should be [3,4,5,6,7], got \(drained)")
}

func testBufferOverfill() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 4) // capacity = 4
    buf.write([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) // write 2.5x capacity

    assert(buf.sampleCount == 4, "sampleCount capped at capacity")
    let drained = buf.drain()
    assert(drained == [7, 8, 9, 10], "should have last 4 samples, got \(drained)")
}

func testBufferResize() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 10)
    buf.write([1, 2, 3])
    buf.resize(durationSeconds: 2, sampleRate: 10) // capacity → 20, resets
    assert(buf.sampleCount == 0, "resize should reset buffer")
}

func testBufferConcurrentAccess() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 48000)
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "test", attributes: .concurrent)
    let iterations = 1000

    // Concurrent writes shouldn't crash
    for i in 0..<iterations {
        group.enter()
        queue.async {
            buf.write([Float(i)])
            group.leave()
        }
    }

    group.wait()
    assert(buf.sampleCount == iterations, "all writes should land, got \(buf.sampleCount)")
}

// ═══════════════════════════════════════════════════════════════
// AudioFileWriter tests
// ═══════════════════════════════════════════════════════════════

func testWavWriteSmall() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_small.wav")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = AudioFileWriter(url: url, format: .wav, quality: .medium)
    do {
        try writer.open()
        let samples = stereoSineWave(seconds: 1.0)
        try writer.append(samples: samples)
        let info = try writer.finalize()

        assert(info.fileSize > 0, "WAV file should have content, got \(info.fileSize) bytes")
        assert(info.duration > 0.9 && info.duration < 1.1, "duration should be ~1s, got \(info.duration)")
        assert(info.url == url, "URL should match")
        // 1s at 16kHz, 16-bit stereo = 64000 bytes + 44 byte header ≈ 64044
        assert(info.fileSize > 60000, "stereo WAV should be ~64KB, got \(info.fileSize)")
    } catch {
        failed += 1
        print("FAIL testWavWriteSmall: \(error)")
    }
}

func testWavWriteLargeBuffer() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_large.wav")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = AudioFileWriter(url: url, format: .wav, quality: .medium)
    do {
        try writer.open()
        // Simulate a 5-minute buffer drain (like the real app does)
        let samples = stereoSineWave(seconds: 300.0)
        try writer.append(samples: samples)
        let info = try writer.finalize()

        assert(info.fileSize > 0, "large WAV should have content")
        assert(info.duration > 299 && info.duration < 301, "duration should be ~300s, got \(info.duration)")
    } catch {
        failed += 1
        print("FAIL testWavWriteLargeBuffer: \(error)")
    }
}

func testM4aWriteSmall() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_small.m4a")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = AudioFileWriter(url: url, format: .m4a, quality: .medium)
    do {
        try writer.open()
        let samples = stereoSineWave(seconds: 1.0)
        try writer.append(samples: samples)
        let info = try writer.finalize()

        assert(info.fileSize > 0, "M4A file should have content, got \(info.fileSize) bytes")
        assert(info.duration > 0.9 && info.duration < 1.1, "duration should be ~1s, got \(info.duration)")
    } catch {
        failed += 1
        print("FAIL testM4aWriteSmall: \(error)")
    }
}

func testM4aWriteLargeBuffer() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_large.m4a")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = AudioFileWriter(url: url, format: .m4a, quality: .medium)
    do {
        try writer.open()
        // This was the failing case: large buffer drain with AAC encoder
        let samples = stereoSineWave(seconds: 300.0)
        try writer.append(samples: samples)
        let info = try writer.finalize()

        assert(info.fileSize > 0, "large M4A should have content")
        assert(info.duration > 299 && info.duration < 301, "duration should be ~300s, got \(info.duration)")
        // Compressed stereo should still be well under 10MB
        assert(info.fileSize < 10_000_000, "300s stereo M4A at 128kbps should be under 10MB, got \(info.fileSize)")
    } catch {
        failed += 1
        print("FAIL testM4aWriteLargeBuffer: \(error)")
    }
}

func testM4aAllQualities() {
    for quality in AudioQuality.allCases {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_\(quality.rawValue).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = AudioFileWriter(url: url, format: .m4a, quality: quality)
        do {
            try writer.open()
            try writer.append(samples: stereoSineWave(seconds: 2.0))
            let info = try writer.finalize()
            assert(info.fileSize > 0, "M4A \(quality.rawValue) should produce non-empty file")
        } catch {
            failed += 1
            print("FAIL testM4aAllQualities(\(quality.rawValue)): \(error)")
        }
    }
}

func testWriterAppendToClosedFile() {
    let writer = AudioFileWriter(
        url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nope.wav"),
        format: .wav, quality: .medium
    )
    assertThrows(try writer.append(samples: [1, 2, 3]), "append to unopened writer should throw")
}

func testWriterMultipleAppends() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_multi.wav")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = AudioFileWriter(url: url, format: .wav, quality: .medium)
    do {
        try writer.open()
        // Simulate many small writes like audio callbacks
        for _ in 0..<100 {
            try writer.append(samples: stereoSineWave(seconds: 0.01))
        }
        let info = try writer.finalize()
        assert(info.duration > 0.9 && info.duration < 1.1, "100x10ms should be ~1s, got \(info.duration)")
        assert(info.fileSize > 0, "file should have content")
    } catch {
        failed += 1
        print("FAIL testWriterMultipleAppends: \(error)")
    }
}

func testWriterEmptyAppend() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_empty_append.wav")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = AudioFileWriter(url: url, format: .wav, quality: .medium)
    do {
        try writer.open()
        try writer.append(samples: [])
        try writer.append(samples: stereoSineWave(seconds: 0.5))
        let info = try writer.finalize()
        assert(info.fileSize > 0, "empty append should be harmless")
    } catch {
        failed += 1
        print("FAIL testWriterEmptyAppend: \(error)")
    }
}

// ═══════════════════════════════════════════════════════════════
// Interleave tests
// ═══════════════════════════════════════════════════════════════

func testInterleaveEqualLengths() {
    let sys: [Float] = [1, 2, 3]
    let mic: [Float] = [4, 5, 6]
    let result = interleave(sys, mic)
    assert(result == [1, 4, 2, 5, 3, 6], "equal lengths: got \(result)")
}

func testInterleaveSystemLonger() {
    let sys: [Float] = [1, 2, 3]
    let mic: [Float] = [4]
    let result = interleave(sys, mic)
    assert(result == [1, 4, 2, 0, 3, 0], "system longer: got \(result)")
}

func testInterleaveMicLonger() {
    let sys: [Float] = [1]
    let mic: [Float] = [4, 5, 6]
    let result = interleave(sys, mic)
    assert(result == [1, 4, 0, 5, 0, 6], "mic longer: got \(result)")
}

func testInterleaveBothEmpty() {
    let result = interleave([], [])
    assert(result.isEmpty, "both empty: got \(result)")
}

func testInterleaveOneEmpty() {
    let sys: [Float] = [1, 2]
    let result = interleave(sys, [])
    assert(result == [1, 0, 2, 0], "mic empty (silence on R): got \(result)")

    let result2 = interleave([], [3, 4])
    assert(result2 == [0, 3, 0, 4], "system empty (silence on L): got \(result2)")
}

// ═══════════════════════════════════════════════════════════════
// Write-through verification tests
// ═══════════════════════════════════════════════════════════════

/// Generates a mono sine wave at a given frequency.
func monoSineWave(seconds: Double, sampleRate: Int = 48000, frequency: Double = 440) -> [Float] {
    let count = Int(seconds * Double(sampleRate))
    return (0..<count).map { Float(sin(Double($0) * 2 * .pi * frequency / Double(sampleRate))) }
}

/// Counts zero-crossings in a signal (used for rough frequency estimation).
func zeroCrossings(_ samples: [Float]) -> Int {
    guard samples.count > 1 else { return 0 }
    var count = 0
    for i in 1..<samples.count {
        if (samples[i - 1] >= 0 && samples[i] < 0) || (samples[i - 1] < 0 && samples[i] >= 0) {
            count += 1
        }
    }
    return count
}

func testWriteThroughVerification() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_writethrough.wav")
    defer { try? FileManager.default.removeItem(at: url) }

    let durationSec = 3.0
    let sampleRate = 48000
    let freqL = 1000.0  // 1kHz on left
    let freqR = 2000.0  // 2kHz on right

    // Generate stereo: 1kHz L, 2kHz R
    let leftChannel = monoSineWave(seconds: durationSec, sampleRate: sampleRate, frequency: freqL)
    let rightChannel = monoSineWave(seconds: durationSec, sampleRate: sampleRate, frequency: freqR)
    let frames = leftChannel.count
    var stereoData = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        stereoData[i * 2]     = leftChannel[i]
        stereoData[i * 2 + 1] = rightChannel[i]
    }

    // Write via AudioFileWriter
    let writer = AudioFileWriter(url: url, format: .wav, quality: .high)
    do {
        try writer.open()
        try writer.append(samples: stereoData)
        let info = try writer.finalize()

        // Verify basic properties
        assert(info.fileSize > 0, "write-through: file should have content")
        assert(info.duration > 2.9 && info.duration < 3.1,
               "write-through: duration should be ~3s, got \(info.duration)")

        // Read back via AVAudioFile
        let audioFile = try AVAudioFile(forReading: url)
        let fileFormat = audioFile.processingFormat

        assert(fileFormat.channelCount == 2, "write-through: should be stereo, got \(fileFormat.channelCount) channels")

        let frameCount = UInt32(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
            failed += 1
            print("FAIL write-through: could not create read buffer")
            return
        }
        try audioFile.read(into: buffer)
        buffer.frameLength = frameCount

        let readDuration = Double(frameCount) / fileFormat.sampleRate
        assert(readDuration > 2.5 && readDuration < 3.5,
               "write-through: read-back duration should be ~3s, got \(readDuration)")

        // Extract L and R channels
        guard let channelData = buffer.floatChannelData else {
            failed += 1
            print("FAIL write-through: no float channel data")
            return
        }
        let readFrames = Int(buffer.frameLength)
        let leftSamples = Array(UnsafeBufferPointer(start: channelData[0], count: readFrames))
        let rightSamples = Array(UnsafeBufferPointer(start: channelData[1], count: readFrames))

        // Verify non-silence: RMS should be well above zero
        let lRMS = sqrt(leftSamples.reduce(Float(0)) { $0 + $1 * $1 } / Float(readFrames))
        let rRMS = sqrt(rightSamples.reduce(Float(0)) { $0 + $1 * $1 } / Float(readFrames))
        assert(lRMS > 0.1, "write-through: L channel should not be silent, RMS=\(lRMS)")
        assert(rRMS > 0.1, "write-through: R channel should not be silent, RMS=\(rRMS)")

        // Verify no zero-gaps in the middle of the signal.
        // Check for runs of 100+ consecutive near-zero samples in L channel.
        var zeroRunLength = 0
        var hasGap = false
        let gapThreshold: Float = 0.001
        let minGapLen = 100
        // Skip first and last 1000 samples (edges may legitimately be near zero)
        let margin = 1000
        if readFrames > margin * 2 {
            for i in margin..<(readFrames - margin) {
                if abs(leftSamples[i]) < gapThreshold {
                    zeroRunLength += 1
                    if zeroRunLength >= minGapLen {
                        hasGap = true
                        break
                    }
                } else {
                    zeroRunLength = 0
                }
            }
        }
        assert(!hasGap, "write-through: detected zero-gap in L channel signal")

        // Frequency verification via zero-crossing count.
        // A sine wave at F Hz has ~2*F zero crossings per second.
        // The WAV writer downsamples to 16kHz, so we use the file's actual sample rate.
        let lCrossings = zeroCrossings(leftSamples)
        let rCrossings = zeroCrossings(rightSamples)
        let lFreqEstimate = Double(lCrossings) / 2.0 / readDuration
        let rFreqEstimate = Double(rCrossings) / 2.0 / readDuration

        // Allow generous tolerance (±30%) since downsampling affects the waveform
        assert(lFreqEstimate > freqL * 0.7 && lFreqEstimate < freqL * 1.3,
               "write-through: L freq should be ~\(freqL)Hz, estimated \(lFreqEstimate)Hz")
        assert(rFreqEstimate > freqR * 0.7 && rFreqEstimate < freqR * 1.3,
               "write-through: R freq should be ~\(freqR)Hz, estimated \(rFreqEstimate)Hz")

    } catch {
        failed += 1
        print("FAIL testWriteThroughVerification: \(error)")
    }
}

// ═══════════════════════════════════════════════════════════════
// Remainder interleave tests (for carry-forward logic)
// ═══════════════════════════════════════════════════════════════

/// Simulates the carry-forward interleave logic from RecordingManager.flushPendingSamples().
/// Returns (stereoOutput, systemRemainder, micRemainder).
func carryForwardInterleave(
    sys: [Float], mic: [Float],
    systemRemainder: inout [Float], micRemainder: inout [Float],
    remainderCap: Int = 24000
) -> [Float] {
    let fullSys = systemRemainder + sys
    let fullMic = micRemainder + mic
    systemRemainder = []
    micRemainder = []

    let sysCount = fullSys.count
    let micCount = fullMic.count

    if sysCount > 0 && micCount > 0 {
        let len = min(sysCount, micCount)
        let stereo = interleave(Array(fullSys.prefix(len)), Array(fullMic.prefix(len)))
        if sysCount > len { systemRemainder = Array(fullSys.suffix(sysCount - len)) }
        if micCount > len { micRemainder = Array(fullMic.suffix(micCount - len)) }
        return stereo
    } else if sysCount == 0 && micCount == 0 {
        return []
    } else if sysCount == 0 && micCount <= remainderCap {
        micRemainder = fullMic
        return []
    } else if micCount == 0 && sysCount <= remainderCap {
        systemRemainder = fullSys
        return []
    } else {
        return interleave(fullSys, fullMic)
    }
}

func testRemainderBothPresent() {
    var sysR: [Float] = []
    var micR: [Float] = []
    let result = carryForwardInterleave(sys: [1, 2, 3], mic: [4, 5], systemRemainder: &sysR, micRemainder: &micR)
    assert(result == [1, 4, 2, 5], "both present: interleave min, got \(result)")
    assert(sysR == [3], "system remainder should be [3], got \(sysR)")
    assert(micR == [], "mic remainder should be [], got \(micR)")
}

func testRemainderOneEmpty() {
    var sysR: [Float] = []
    var micR: [Float] = []
    // System has data, mic empty — under cap, carry forward
    let result = carryForwardInterleave(sys: [1, 2], mic: [], systemRemainder: &sysR, micRemainder: &micR)
    assert(result == [], "one empty under cap: should carry forward, got \(result)")
    assert(sysR == [1, 2], "system should be carried, got \(sysR)")
}

func testRemainderCarryForwardAccumulates() {
    var sysR: [Float] = [10, 20]
    var micR: [Float] = []
    // Previous remainder + new data
    let result = carryForwardInterleave(sys: [30], mic: [1, 2], systemRemainder: &sysR, micRemainder: &micR)
    // fullSys = [10, 20, 30], fullMic = [1, 2], min = 2
    assert(result == [10, 1, 20, 2], "carry accumulates: got \(result)")
    assert(sysR == [30], "system remainder should be [30], got \(sysR)")
}

func testRemainderOverCap() {
    var sysR: [Float] = []
    var micR: [Float] = []
    // System has data exceeding cap, mic empty — flush with zero-pad
    let bigSys = [Float](repeating: 1, count: 25000)
    let result = carryForwardInterleave(sys: bigSys, mic: [], systemRemainder: &sysR, micRemainder: &micR)
    assert(result.count == 25000 * 2, "over cap: should flush with padding, got \(result.count)")
    assert(sysR == [], "no remainder after flush")
}

func testRemainderBothEmpty() {
    var sysR: [Float] = []
    var micR: [Float] = []
    let result = carryForwardInterleave(sys: [], mic: [], systemRemainder: &sysR, micRemainder: &micR)
    assert(result == [], "both empty: got \(result)")
}

// ═══════════════════════════════════════════════════════════════
// CircularAudioBuffer bar peak tests
// ═══════════════════════════════════════════════════════════════

func testBarPeakLiveBar() {
    // Write fewer than samplesPerBar — only the live bar (index 99) should be non-zero
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 1000) // samplesPerBar = 10
    buf.write([0.5, -0.8, 0.3])
    let peaks = buf.getBarPeaks()
    assert(peaks.count == 100, "bar peaks should have 100 entries")
    assert(peaks[99] == Float(0.8), "live bar should be 0.8 (max abs), got \(peaks[99])")
    for i in 0..<99 {
        assert(peaks[i] == 0, "bar \(i) should be 0 (no commits yet), got \(peaks[i])")
    }
}

func testBarPeakSingleCommit() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 1000) // samplesPerBar = 10
    let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    buf.write(samples)
    let peaks = buf.getBarPeaks()
    assert(peaks[98] == Float(1.0), "committed bar peak = 1.0, got \(peaks[98])")
    assert(peaks[99] == 0, "live bar = 0 after exact commit, got \(peaks[99])")
}

func testBarPeakWithPartialBar() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 1000)
    // 1 committed bar (10 samples) + 5 partial
    var samples = [Float](repeating: 0.3, count: 10)
    samples += [0.1, 0.2, 0.9, 0.4, 0.5]
    buf.write(samples)
    let peaks = buf.getBarPeaks()
    assert(peaks[98] == Float(0.3), "committed bar peak = 0.3, got \(peaks[98])")
    assert(peaks[99] == Float(0.9), "live bar peak = 0.9, got \(peaks[99])")
}

func testBarPeakOrdering() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 1000)
    // Write 3 bars with distinct peaks
    var samples = [Float]()
    for _ in 0..<10 { samples.append(0.3) }
    for _ in 0..<10 { samples.append(0.6) }
    for _ in 0..<10 { samples.append(0.9) }
    buf.write(samples)
    let peaks = buf.getBarPeaks()
    assert(peaks[96] == Float(0.3), "oldest bar = 0.3, got \(peaks[96])")
    assert(peaks[97] == Float(0.6), "middle bar = 0.6, got \(peaks[97])")
    assert(peaks[98] == Float(0.9), "newest bar = 0.9, got \(peaks[98])")
    assert(peaks[99] == 0, "live bar = 0 after exact commits, got \(peaks[99])")
}

func testBarPeakNegativeSamples() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 1000)
    buf.write([-0.7, 0.3, -0.5])
    let peaks = buf.getBarPeaks()
    assert(peaks[99] == Float(0.7), "live bar tracks abs of negative samples, got \(peaks[99])")
}

func testBarPeakWrapAround() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 1000)
    // samplesPerBar = 10; write 105 bars to wrap the 100-slot circular bar array
    for barIdx in 0..<105 {
        let peak = Float(barIdx + 1) * 0.009 // 0.009, 0.018, ..., 0.945
        var barSamples = [Float](repeating: 0, count: 10)
        barSamples[0] = peak
        buf.write(barSamples)
    }
    let peaks = buf.getBarPeaks()
    let tolerance: Float = 0.001
    // 99 most recent committed bars: indices 6..104 (peaks 0.063..0.945)
    assert(abs(peaks[0] - 0.063) < tolerance, "oldest visible bar = 0.063, got \(peaks[0])")
    assert(abs(peaks[98] - 0.945) < tolerance, "newest committed bar = 0.945, got \(peaks[98])")
    assert(peaks[99] == 0, "live bar = 0 (all exact commits), got \(peaks[99])")
}

func testBarPeakAfterDrain() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 1000)
    buf.write([Float](repeating: 0.5, count: 20)) // 2 committed bars
    _ = buf.drain()
    let peaks = buf.getBarPeaks()
    for i in 0..<100 {
        assert(peaks[i] == 0, "bar \(i) should be 0 after drain, got \(peaks[i])")
    }
}

func testMeterPeakConsume() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 1000)
    buf.write([0.3, -0.8, 0.5])
    let peak = buf.consumeMeterPeak()
    assert(peak == Float(0.8), "meter peak = 0.8, got \(peak)")
    let peak2 = buf.consumeMeterPeak()
    assert(peak2 == 0, "meter peak after consume = 0, got \(peak2)")
}

func testMeterPeakAccumulates() {
    let buf = CircularAudioBuffer(durationSeconds: 1, sampleRate: 1000)
    buf.write([0.3])
    buf.write([0.8])
    buf.write([0.5])
    let peak = buf.consumeMeterPeak()
    assert(peak == Float(0.8), "meter peak accumulates across writes = 0.8, got \(peak)")
}

// ═══════════════════════════════════════════════════════════════
// Mic → waveform pipeline simulation tests
// ═══════════════════════════════════════════════════════════════

func testMicOnlyWaveform() {
    // Simulate: mic has signal, system is silent.
    // The waveform should show mic signal.
    let sysBuffer = CircularAudioBuffer(durationSeconds: 10, sampleRate: 1000) // samplesPerBar = 100
    let micBuffer = CircularAudioBuffer(durationSeconds: 10, sampleRate: 1000)

    // Write silence to system
    sysBuffer.write([Float](repeating: 0, count: 500))
    // Write mic signal (sine wave)
    let micSamples = sineWave(seconds: 0.5, sampleRate: 1000, frequency: 100)
    micBuffer.write(micSamples)

    let sysRaw = sysBuffer.getBarPeaks()
    let micRaw = micBuffer.getBarPeaks()

    // Merge with max (same as RecordingManager.startWaveformTimer)
    var merged = [Float](repeating: 0, count: 100)
    for i in 0..<100 {
        merged[i] = max(sysRaw[i], micRaw[i])
    }

    // With 500 samples and samplesPerBar=100, we have 5 committed bars + live bar
    let nonZeroBars = merged.filter { $0 > 0.01 }.count
    assert(nonZeroBars >= 5, "mic-only: should have ≥5 non-zero bars, got \(nonZeroBars)")

    // System bars should all be zero
    for i in 0..<100 {
        assert(sysRaw[i] == 0, "system bar \(i) should be 0 (silence), got \(sysRaw[i])")
    }
}

func testBothSourcesMerge() {
    let sysBuffer = CircularAudioBuffer(durationSeconds: 10, sampleRate: 1000) // samplesPerBar = 100
    let micBuffer = CircularAudioBuffer(durationSeconds: 10, sampleRate: 1000)

    // System: peak 0.3 per bar; Mic: peak 0.7 per bar
    sysBuffer.write([Float](repeating: 0.3, count: 200))
    micBuffer.write([Float](repeating: 0.7, count: 200))

    let sysRaw = sysBuffer.getBarPeaks()
    let micRaw = micBuffer.getBarPeaks()

    var merged = [Float](repeating: 0, count: 100)
    for i in 0..<100 {
        merged[i] = max(sysRaw[i], micRaw[i])
    }

    // Committed bars (2 bars each) — merged should take the louder (mic = 0.7)
    assert(merged[97] == Float(0.7), "merged bar = max(0.3, 0.7) = 0.7, got \(merged[97])")
    assert(merged[98] == Float(0.7), "merged bar = max(0.3, 0.7) = 0.7, got \(merged[98])")
}

func testWaveformDirectAssignment() {
    // Simulate the direct-assignment logic (no smoothing) from waveformTimer
    let sysBuffer = CircularAudioBuffer(durationSeconds: 10, sampleRate: 1000)
    let micBuffer = CircularAudioBuffer(durationSeconds: 10, sampleRate: 1000)

    // Write distinct peaks to each buffer
    sysBuffer.write([Float](repeating: 0.3, count: 200))
    micBuffer.write([Float](repeating: 0.7, count: 200))

    let sysRaw = sysBuffer.getBarPeaks()
    let micRaw = micBuffer.getBarPeaks()

    // Merge with max (same as RecordingManager)
    var raw = [Float](repeating: 0, count: 100)
    for i in 0..<100 {
        raw[i] = max(sysRaw[i], micRaw[i])
    }

    // Direct assignment — amplitudes should exactly equal merged peaks
    assert(raw[97] == Float(0.7), "direct assignment: bar 97 = 0.7, got \(raw[97])")
    assert(raw[98] == Float(0.7), "direct assignment: bar 98 = 0.7, got \(raw[98])")

    // Verify no ghosting: bars without data should be exactly 0
    assert(raw[0] == 0, "direct assignment: empty bar 0 = 0, got \(raw[0])")
    assert(raw[50] == 0, "direct assignment: empty bar 50 = 0, got \(raw[50])")
}

func testFilledBarCount() {
    // Simulate filledBarCount logic: samples / samplesPerBar + 1
    let samplesPerBar = 100 // bufferDuration(10) * sampleRate(1000) / 100

    func filledBars(_ samples: Int) -> Int {
        min(100, samples / max(1, samplesPerBar) + 1)
    }

    assert(filledBars(0) == 1, "no samples: filledBarCount = 1 (live bar)")
    assert(filledBars(50) == 1, "50 samples: filledBarCount = 1 (partial bar)")
    assert(filledBars(100) == 2, "100 samples: filledBarCount = 2")
    assert(filledBars(500) == 6, "500 samples: filledBarCount = 6")
    assert(filledBars(10000) == 100, "full buffer: clamped to 100")
    assert(filledBars(15000) == 100, "overfull: clamped to 100")
}

func testMicSineWaveBarPeaks() {
    // Write a realistic sine wave and verify bar peaks match expected amplitudes
    let buf = CircularAudioBuffer(durationSeconds: 10, sampleRate: 1000) // samplesPerBar = 100
    let samples = sineWave(seconds: 1.0, sampleRate: 1000, frequency: 50)
    // 50Hz at 1000Hz SR → period = 20 samples. 100 samples/bar → 5 full periods per bar.
    // Peak of sin = 1.0, so each committed bar peak should be ~1.0
    buf.write(samples)
    let peaks = buf.getBarPeaks()

    // 1000 samples / 100 per bar = 10 committed bars
    // Bars should be at indices 89..98, live bar at 99 (empty since exact multiple)
    for i in 89...98 {
        assert(peaks[i] > 0.9, "sine bar \(i) peak should be ~1.0, got \(peaks[i])")
    }
}

func testMicWeakSignalStillVisible() {
    // Even quiet mic signal should produce non-zero bar peaks
    let sysBuffer = CircularAudioBuffer(durationSeconds: 10, sampleRate: 1000)
    let micBuffer = CircularAudioBuffer(durationSeconds: 10, sampleRate: 1000)

    // System is silent, mic has very quiet signal (0.02 peak — typical quiet ambient)
    sysBuffer.write([Float](repeating: 0, count: 200))
    var quietMic = [Float](repeating: 0, count: 200)
    for i in stride(from: 0, to: 200, by: 10) { quietMic[i] = 0.02 }
    micBuffer.write(quietMic)

    let sysRaw = sysBuffer.getBarPeaks()
    let micRaw = micBuffer.getBarPeaks()

    var merged = [Float](repeating: 0, count: 100)
    for i in 0..<100 {
        merged[i] = max(sysRaw[i], micRaw[i])
    }

    // Quiet signal should still produce non-zero peaks
    let hasSignal = merged.contains { $0 > 0 }
    assert(hasSignal, "even quiet mic signal (0.02 peak) should produce non-zero merged bars")
}


// ═══════════════════════════════════════════════════════════════
// Run all tests
// ═══════════════════════════════════════════════════════════════

@main
struct TestRunner {
    static func main() {
        print("Running CircularAudioBuffer tests...")
        testBufferBasicWriteAndDrain()
        testBufferDrainEmpty()
        testBufferWrapAround()
        testBufferOverfill()
        testBufferResize()
        testBufferConcurrentAccess()

        print("Running AudioFileWriter tests...")
        testWavWriteSmall()
        testWavWriteLargeBuffer()
        testM4aWriteSmall()
        testM4aWriteLargeBuffer()
        testM4aAllQualities()
        testWriterAppendToClosedFile()
        testWriterMultipleAppends()
        testWriterEmptyAppend()

        print("Running interleave tests...")
        testInterleaveEqualLengths()
        testInterleaveSystemLonger()
        testInterleaveMicLonger()
        testInterleaveBothEmpty()
        testInterleaveOneEmpty()

        print("Running write-through verification...")
        testWriteThroughVerification()

        print("Running remainder interleave tests...")
        testRemainderBothPresent()
        testRemainderOneEmpty()
        testRemainderCarryForwardAccumulates()
        testRemainderOverCap()
        testRemainderBothEmpty()

        print("Running bar peak tests...")
        testBarPeakLiveBar()
        testBarPeakSingleCommit()
        testBarPeakWithPartialBar()
        testBarPeakOrdering()
        testBarPeakNegativeSamples()
        testBarPeakWrapAround()
        testBarPeakAfterDrain()
        testMeterPeakConsume()
        testMeterPeakAccumulates()

        print("Running mic → waveform pipeline tests...")
        testMicOnlyWaveform()
        testBothSourcesMerge()
        testWaveformDirectAssignment()
        testFilledBarCount()
        testMicSineWaveBarPeaks()
        testMicWeakSignalStillVisible()

        print("\n\(passed) passed, \(failed) failed")
        exit(failed > 0 ? 1 : 0)
    }
}
