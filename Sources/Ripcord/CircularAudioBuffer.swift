import Foundation

/// Canonical capture clock. Every audio range in the recording pipeline is
/// expressed as an absolute, half-open `[start, end)` range at 48 kHz.
typealias CaptureFrame = Int64

struct CaptureFrameRange: Equatable, Sendable {
    var start: CaptureFrame
    var end: CaptureFrame

    init(_ start: CaptureFrame, _ end: CaptureFrame) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    var count: Int { Int(end - start) }
    var isEmpty: Bool { start == end }
    func clamped(to bounds: CaptureFrameRange) -> CaptureFrameRange {
        CaptureFrameRange(max(start, bounds.start), max(max(start, bounds.start), min(end, bounds.end)))
    }
}

struct AudioBufferSnapshot: Sendable {
    let range: CaptureFrameRange
    let samples: [Float]
}

/// Stereo-interleaved ring buffer. Storage remains bounded, but its public
/// boundary is a CaptureFrame range rather than an array-relative offset.
final class CircularAudioBuffer: @unchecked Sendable {
    static let channelsPerFrame = 2

    private var capacityFrames: Int
    private var buffer: [Float]
    private var writeHead = 0
    private var totalWritten = 0
    private var oldestFrame: CaptureFrame?
    private var latestFrame: CaptureFrame?
    private var latestEndHostTime: UInt64?
    private let lock = NSLock()
    private var meterPeakAccum: Float = 0

    init(durationSeconds: Int, sampleRate: Int = 48000) {
        capacityFrames = durationSeconds * sampleRate
        buffer = [Float](repeating: 0, count: capacityFrames * Self.channelsPerFrame)
    }

    var frameCount: Int { lock.withLock { min(totalWritten, capacityFrames) } }
    var visibleRange: CaptureFrameRange? {
        lock.withLock {
            guard let oldestFrame, let latestFrame else { return nil }
            return CaptureFrameRange(oldestFrame, latestFrame)
        }
    }

    func write(_ samples: UnsafeBufferPointer<Float>, startFrame: CaptureFrame? = nil,
               endHostTime: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let frames = samples.count / Self.channelsPerFrame
        guard frames > 0, capacityFrames > 0 else { return }
        let incomingStart = startFrame ?? latestFrame ?? 0
        var sourceOffsetFrames = 0
        var framesToWrite = frames

        if latestFrame == nil {
            resetLocked(at: incomingStart)
        } else if let latestFrame {
            let delta = incomingStart - latestFrame
            if delta >= CaptureFrame(capacityFrames) || delta <= -CaptureFrame(capacityFrames) {
                // A route/device restart can jump to an unrelated clock epoch.
                // Rebase instead of letting absolute-frame math diverge from ring storage.
                resetLocked(at: incomingStart)
            } else if delta > 0 {
                appendSilenceLocked(frames: Int(delta))
                self.latestFrame = latestFrame + delta
            } else if delta < 0 {
                let overlap = Int(-delta)
                guard overlap < frames else { return }
                sourceOffsetFrames = overlap
                framesToWrite -= overlap
            }
        }

        appendSamplesLocked(
            samples,
            sourceOffsetFrames: sourceOffsetFrames,
            frameCount: framesToWrite
        )
        let appendStart = latestFrame ?? incomingStart
        latestFrame = appendStart + CaptureFrame(framesToWrite)
        if let latestFrame {
            oldestFrame = latestFrame - CaptureFrame(totalWritten)
        }
        if let endHostTime { latestEndHostTime = endHostTime }
    }

    private func resetLocked(at frame: CaptureFrame) {
        writeHead = 0
        totalWritten = 0
        oldestFrame = frame
        latestFrame = frame
        latestEndHostTime = nil
    }

    private func appendSamplesLocked(
        _ samples: UnsafeBufferPointer<Float>,
        sourceOffsetFrames: Int,
        frameCount: Int
    ) {
        let capacitySamples = capacityFrames * Self.channelsPerFrame
        let startSample = sourceOffsetFrames * Self.channelsPerFrame
        let sampleCount = frameCount * Self.channelsPerFrame
        for index in startSample..<(startSample + sampleCount) {
            buffer[writeHead] = samples[index]
            writeHead = (writeHead + 1) % capacitySamples
            meterPeakAccum = max(meterPeakAccum, abs(samples[index]))
        }
        totalWritten = min(capacityFrames, totalWritten + frameCount)
    }

    private func appendSilenceLocked(frames: Int) {
        guard frames > 0 else { return }
        let capacitySamples = capacityFrames * Self.channelsPerFrame
        let sampleCount = frames * Self.channelsPerFrame
        if sampleCount >= capacitySamples {
            buffer = [Float](repeating: 0, count: capacitySamples)
            writeHead = (writeHead + sampleCount) % capacitySamples
        } else {
            let firstCount = min(sampleCount, capacitySamples - writeHead)
            buffer.replaceSubrange(
                writeHead..<(writeHead + firstCount),
                with: repeatElement(0, count: firstCount)
            )
            let remainder = sampleCount - firstCount
            if remainder > 0 {
                buffer.replaceSubrange(
                    0..<remainder,
                    with: repeatElement(0, count: remainder)
                )
            }
            writeHead = (writeHead + sampleCount) % capacitySamples
        }
        totalWritten = min(capacityFrames, totalWritten + frames)
    }

    /// Chronological snapshot for an absolute range. Requests outside the
    /// visible window are clipped; callers can use `range` to see precisely
    /// what was retained.
    func snapshot(range requested: CaptureFrameRange? = nil) -> AudioBufferSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let visible = visibleRangeLocked else {
            return AudioBufferSnapshot(range: CaptureFrameRange(0, 0), samples: [])
        }
        let range = (requested ?? visible).clamped(to: visible)
        guard !range.isEmpty else { return AudioBufferSnapshot(range: range, samples: []) }
        let available = min(totalWritten, capacityFrames)
        let firstFrame = visible.end - CaptureFrame(available)
        let offsetFrames = Int(range.start - firstFrame)
        let countSamples = range.count * Self.channelsPerFrame
        let capacitySamples = capacityFrames * Self.channelsPerFrame
        let startSample = (writeHead - available * Self.channelsPerFrame + offsetFrames * Self.channelsPerFrame + capacitySamples) % capacitySamples
        var samples = [Float](repeating: 0, count: countSamples)
        if startSample + countSamples <= capacitySamples {
            samples[0..<countSamples] = buffer[startSample..<(startSample + countSamples)]
        } else {
            let first = capacitySamples - startSample
            samples[0..<first] = buffer[startSample..<capacitySamples]
            samples[first..<countSamples] = buffer[0..<(countSamples - first)]
        }
        return AudioBufferSnapshot(range: range, samples: samples)
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard let visible = visibleRangeLocked else { return [] }
        let result = snapshotLocked(range: visible)
        writeHead = 0; totalWritten = 0; oldestFrame = nil; latestFrame = nil; latestEndHostTime = nil
        return result.samples
    }

    func read(lastNFrames count: Int) -> [Float] { snapshotLast(count).samples }
    func readWithEndHostTime(lastNFrames count: Int) -> (samples: [Float], endHostTime: UInt64?) {
        lock.withLock { (snapshotLastLocked(count).samples, latestEndHostTime) }
    }
    func snapshotLast(_ count: Int) -> AudioBufferSnapshot { lock.withLock { snapshotLastLocked(count) } }

    private var visibleRangeLocked: CaptureFrameRange? {
        guard let oldestFrame, let latestFrame else { return nil }
        return CaptureFrameRange(oldestFrame, latestFrame)
    }
    private func snapshotLastLocked(_ count: Int) -> AudioBufferSnapshot {
        guard let visible = visibleRangeLocked else { return AudioBufferSnapshot(range: CaptureFrameRange(0, 0), samples: []) }
        return snapshotLocked(range: CaptureFrameRange(max(visible.start, visible.end - CaptureFrame(count)), visible.end))
    }
    private func snapshotLocked(range: CaptureFrameRange) -> AudioBufferSnapshot {
        // Caller already owns lock.
        guard let visible = visibleRangeLocked else { return AudioBufferSnapshot(range: CaptureFrameRange(0, 0), samples: []) }
        let clipped = range.clamped(to: visible)
        guard !clipped.isEmpty else { return AudioBufferSnapshot(range: clipped, samples: []) }
        let available = min(totalWritten, capacityFrames)
        let offset = Int(clipped.start - (visible.end - CaptureFrame(available)))
        let count = clipped.count * Self.channelsPerFrame
        let capacity = capacityFrames * Self.channelsPerFrame
        let start = (writeHead - available * Self.channelsPerFrame + offset * Self.channelsPerFrame + capacity) % capacity
        var samples = [Float](repeating: 0, count: count)
        if start + count <= capacity { samples[0..<count] = buffer[start..<(start + count)] }
        else { let n = capacity - start; samples[0..<n] = buffer[start..<capacity]; samples[n..<count] = buffer[0..<(count - n)] }
        return AudioBufferSnapshot(range: clipped, samples: samples)
    }

    func consumeMeterPeak() -> Float { lock.withLock { defer { meterPeakAccum = 0 }; return meterPeakAccum } }
    func resize(durationSeconds: Int, sampleRate: Int = 48000) {
        lock.withLock {
            capacityFrames = durationSeconds * sampleRate
            buffer = [Float](repeating: 0, count: capacityFrames * Self.channelsPerFrame)
            writeHead = 0; totalWritten = 0; oldestFrame = nil; latestFrame = nil; meterPeakAccum = 0; latestEndHostTime = nil
        }
    }
}
