import Foundation
import os

/// Bounded single-producer/single-consumer handoff for CoreAudio callbacks.
///
/// The producer side never blocks: if the consumer is draining at the same
/// moment, the incoming chunk is dropped rather than stalling the real-time
/// audio thread. In the normal case it copies into pre-allocated storage and
/// returns immediately; heavier work happens on RecordingManager's processing
/// queue after `drain()`.
final class AudioSampleHandoff: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var buffer: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var storedCount = 0
    private var droppedSamples = 0

    init(capacityFrames: Int, channelsPerFrame: Int = CircularAudioBuffer.channelsPerFrame) {
        let capacitySamples = max(channelsPerFrame, capacityFrames * channelsPerFrame)
        self.buffer = [Float](repeating: 0, count: capacitySamples)
    }

    func write(_ samples: UnsafeBufferPointer<Float>) {
        guard samples.count > 0, let base = samples.baseAddress else { return }

        guard os_unfair_lock_trylock(&lock) else {
            return
        }
        defer { os_unfair_lock_unlock(&lock) }

        let capacity = buffer.count
        if samples.count >= capacity {
            let start = samples.count - capacity
            buffer.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: base.advanced(by: start), count: capacity)
            }
            readIndex = 0
            writeIndex = 0
            droppedSamples += storedCount + start
            storedCount = capacity
            return
        }

        let free = capacity - storedCount
        if samples.count > free {
            let drop = samples.count - free
            readIndex = (readIndex + drop) % capacity
            storedCount -= drop
            droppedSamples += drop
        }

        let firstCopy = min(samples.count, capacity - writeIndex)
        buffer.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.advanced(by: writeIndex).update(from: base, count: firstCopy)
            if samples.count > firstCopy {
                dst.baseAddress!.update(from: base.advanced(by: firstCopy), count: samples.count - firstCopy)
            }
        }
        writeIndex = (writeIndex + samples.count) % capacity
        storedCount += samples.count
    }

    func drain() -> (samples: [Float], droppedSamples: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let count = storedCount
        let dropped = droppedSamples
        droppedSamples = 0
        guard count > 0 else { return ([], dropped) }

        var out = [Float](repeating: 0, count: count)
        let capacity = buffer.count
        let firstCopy = min(count, capacity - readIndex)
        out.withUnsafeMutableBufferPointer { dst in
            buffer.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!.advanced(by: readIndex), count: firstCopy)
                if count > firstCopy {
                    dst.baseAddress!.advanced(by: firstCopy).update(from: src.baseAddress!, count: count - firstCopy)
                }
            }
        }

        readIndex = writeIndex
        storedCount = 0
        return (out, dropped)
    }
}
