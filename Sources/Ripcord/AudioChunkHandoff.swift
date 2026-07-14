import CoreAudio
import Darwin
import Foundation
import os

/// Bounded timestamped handoff whose producer path performs no allocation.
final class AudioChunkHandoff: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var samples: [Float]
    private var chunkStarts: [Int]
    private var chunkCounts: [Int]
    private var chunkTimings: [AudioSampleTiming?]
    private var sampleWriteIndex = 0
    private var storedSamples = 0
    private var chunkReadIndex = 0
    private var chunkWriteIndex = 0
    private var storedChunks = 0
    private var droppedSamples = 0
    private var contentionDroppedSamples: Int64 = 0
    private var reportedContentionDroppedSamples: Int64 = 0

    init(capacityFrames: Int, channelsPerFrame: Int = CircularAudioBuffer.channelsPerFrame) {
        let capacitySamples = max(channelsPerFrame, capacityFrames * channelsPerFrame)
        samples = [Float](repeating: 0, count: capacitySamples)
        let metadataCapacity = 1024
        chunkStarts = [Int](repeating: 0, count: metadataCapacity)
        chunkCounts = [Int](repeating: 0, count: metadataCapacity)
        chunkTimings = [AudioSampleTiming?](repeating: nil, count: metadataCapacity)
    }

    func write(_ input: UnsafeBufferPointer<Float>, timing: AudioSampleTiming) {
        guard input.count > 0, let base = input.baseAddress else { return }
        guard os_unfair_lock_trylock(&lock) else {
            OSAtomicAdd64Barrier(Int64(input.count), &contentionDroppedSamples)
            return
        }
        defer { os_unfair_lock_unlock(&lock) }

        let capacity = samples.count
        let keptCount = min(input.count, capacity)
        let sourceOffset = input.count - keptCount
        let keptTiming = sourceOffset > 0
            ? timing.advanced(byFrames: sourceOffset / max(1, timing.channelsPerFrame))
            : timing
        if sourceOffset > 0 { droppedSamples += sourceOffset }

        while storedChunks > 0,
              storedSamples + keptCount > capacity || storedChunks == chunkStarts.count {
            evictOldestChunk()
        }

        let firstCopy = min(keptCount, capacity - sampleWriteIndex)
        samples.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.advanced(by: sampleWriteIndex)
                .update(from: base.advanced(by: sourceOffset), count: firstCopy)
            if keptCount > firstCopy {
                destination.baseAddress!.update(
                    from: base.advanced(by: sourceOffset + firstCopy),
                    count: keptCount - firstCopy)
            }
        }

        chunkStarts[chunkWriteIndex] = sampleWriteIndex
        chunkCounts[chunkWriteIndex] = keptCount
        chunkTimings[chunkWriteIndex] = keptTiming
        chunkWriteIndex = (chunkWriteIndex + 1) % chunkStarts.count
        storedChunks += 1
        storedSamples += keptCount
        sampleWriteIndex = (sampleWriteIndex + keptCount) % capacity
    }

    func drain() -> (chunks: [AudioSampleChunk], droppedSamples: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        var output: [AudioSampleChunk] = []
        output.reserveCapacity(storedChunks)
        let capacity = samples.count
        for _ in 0..<storedChunks {
            let index = chunkReadIndex
            let count = chunkCounts[index]
            if let timing = chunkTimings[index], count > 0 {
                var copied = [Float](repeating: 0, count: count)
                let start = chunkStarts[index]
                let firstCopy = min(count, capacity - start)
                copied.withUnsafeMutableBufferPointer { destination in
                    samples.withUnsafeBufferPointer { source in
                        destination.baseAddress!.update(
                            from: source.baseAddress!.advanced(by: start), count: firstCopy)
                        if count > firstCopy {
                            destination.baseAddress!.advanced(by: firstCopy)
                                .update(from: source.baseAddress!, count: count - firstCopy)
                        }
                    }
                }
                output.append(AudioSampleChunk(samples: copied, timing: timing))
            }
            chunkTimings[index] = nil
            chunkReadIndex = (chunkReadIndex + 1) % chunkStarts.count
        }

        storedChunks = 0
        storedSamples = 0
        chunkReadIndex = chunkWriteIndex
        let contentionTotal = OSAtomicAdd64Barrier(0, &contentionDroppedSamples)
        let contentionDelta = max(0, contentionTotal - reportedContentionDroppedSamples)
        reportedContentionDroppedSamples = contentionTotal
        let dropped = droppedSamples + Int(contentionDelta)
        droppedSamples = 0
        return (output, dropped)
    }

    private func evictOldestChunk() {
        let count = chunkCounts[chunkReadIndex]
        storedSamples -= count
        droppedSamples += count
        chunkTimings[chunkReadIndex] = nil
        chunkReadIndex = (chunkReadIndex + 1) % chunkStarts.count
        storedChunks -= 1
    }
}

private extension AudioSampleTiming {
    func advanced(byFrames frames: Int) -> AudioSampleTiming {
        let nanos = AudioConvertHostTimeToNanos(hostTime)
            + UInt64(Double(frames) * 1_000_000_000.0 / sampleRate)
        return AudioSampleTiming(
            hostTime: AudioConvertNanosToHostTime(nanos),
            sampleTime: sampleTime.map { $0 + Double(frames) },
            sampleRate: sampleRate,
            channelsPerFrame: channelsPerFrame
        )
    }
}
