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
        guard frames > 0 else { return }
        let start = startFrame ?? latestFrame ?? 0
        let capacitySamples = capacityFrames * Self.channelsPerFrame
        for i in 0..<samples.count {
            buffer[writeHead] = samples[i]
            writeHead = (writeHead + 1) % capacitySamples
            meterPeakAccum = max(meterPeakAccum, abs(samples[i]))
        }
        totalWritten += frames
        let end = start + CaptureFrame(frames)
        latestFrame = end
        if totalWritten <= capacityFrames {
            oldestFrame = oldestFrame ?? start
        } else {
            oldestFrame = end - CaptureFrame(capacityFrames)
        }
        if let endHostTime { latestEndHostTime = endHostTime }
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
