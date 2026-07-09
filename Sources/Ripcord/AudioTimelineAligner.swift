import Foundation
import os.log

private let timelineLogger = Logger(subsystem: "com.vibe.ripcord", category: "TimelineAligner")

final class AudioTimelineAligner {
    private var systemChunks: [AudioSampleChunk] = []
    private var micChunks: [AudioSampleChunk] = []
    private var baselineFrame: Int64?
    private var nextOutputFrame: Int64 = 0
    private let oneSidedFlushFrames: Int64

    init(oneSidedFlushFrames: Int = 24_000) {
        self.oneSidedFlushFrames = Int64(oneSidedFlushFrames)
    }

    func reset() {
        systemChunks.removeAll(keepingCapacity: true)
        micChunks.removeAll(keepingCapacity: true)
        baselineFrame = nil
        nextOutputFrame = 0
    }

    func append(system newSystem: [AudioSampleChunk], mic newMic: [AudioSampleChunk],
                micAdvanceFrames: Int, split: Bool, force: Bool) -> [Float] {
        systemChunks.append(contentsOf: newSystem)
        micChunks.append(contentsOf: newMic.map { $0.shiftedStart(by: -Int64(micAdvanceFrames)) })

        guard !systemChunks.isEmpty || !micChunks.isEmpty else { return [] }
        establishBaseline()

        guard let renderEnd = computeRenderEnd(force: force), renderEnd > nextOutputFrame else {
            return []
        }

        let rendered = render(from: nextOutputFrame, to: renderEnd, split: split)
        consume(before: renderEnd)
        nextOutputFrame = renderEnd
        return rendered
    }

    private func establishBaseline() {
        guard baselineFrame == nil else { return }
        let starts = (systemChunks.map(\.startFrame) + micChunks.map(\.startFrame))
        guard let first = starts.min() else { return }
        baselineFrame = first
        nextOutputFrame = 0
    }

    private func relativeStart(_ chunk: AudioSampleChunk) -> Int64 {
        chunk.startFrame - (baselineFrame ?? chunk.startFrame)
    }

    private func relativeEnd(_ chunk: AudioSampleChunk) -> Int64 {
        relativeStart(chunk) + Int64(chunk.frameCount)
    }

    private func computeRenderEnd(force: Bool) -> Int64? {
        let sysEnd = systemChunks.map(relativeEnd).max()
        let micEnd = micChunks.map(relativeEnd).max()

        if force {
            return [sysEnd, micEnd].compactMap { $0 }.max()
        }

        switch (sysEnd, micEnd) {
        case let (.some(s), .some(m)):
            return min(s, m)
        case let (.some(s), .none):
            return s - nextOutputFrame >= oneSidedFlushFrames ? s : nil
        case let (.none, .some(m)):
            return m - nextOutputFrame >= oneSidedFlushFrames ? m : nil
        case (.none, .none):
            return nil
        }
    }

    private func render(from start: Int64, to end: Int64, split: Bool) -> [Float] {
        let frames = Int(end - start)
        guard frames > 0 else { return [] }

        let ch = CircularAudioBuffer.channelsPerFrame
        var system = [Float](repeating: 0, count: frames * ch)
        var mic = [Float](repeating: 0, count: frames * ch)
        fill(source: systemChunks, into: &system, renderStart: start)
        fill(source: micChunks, into: &mic, renderStart: start)
        return split ? Self.interleave(system, mic) : Self.mixStereo(system, mic)
    }

    private func fill(source chunks: [AudioSampleChunk], into output: inout [Float], renderStart: Int64) {
        let ch = CircularAudioBuffer.channelsPerFrame
        let renderEnd = renderStart + Int64(output.count / ch)

        for chunk in chunks {
            let chunkStart = relativeStart(chunk)
            let chunkEnd = relativeEnd(chunk)
            let copyStart = max(renderStart, chunkStart)
            let copyEnd = min(renderEnd, chunkEnd)
            guard copyEnd > copyStart else { continue }

            let sourceFrame = Int(copyStart - chunkStart)
            let destFrame = Int(copyStart - renderStart)
            let frames = Int(copyEnd - copyStart)
            let sourceSample = sourceFrame * ch
            let destSample = destFrame * ch
            let sampleCount = frames * ch
            guard sourceSample + sampleCount <= chunk.samples.count,
                  destSample + sampleCount <= output.count else {
                timelineLogger.error("Timeline copy bounds rejected")
                continue
            }
            output[destSample..<(destSample + sampleCount)] =
                chunk.samples[sourceSample..<(sourceSample + sampleCount)]
        }
    }

    private func consume(before frame: Int64) {
        systemChunks = systemChunks.compactMap { chunk in
            chunk.trimming(before: frame + (baselineFrame ?? 0))
        }
        micChunks = micChunks.compactMap { chunk in
            chunk.trimming(before: frame + (baselineFrame ?? 0))
        }
    }

    private static func interleave(_ system: [Float], _ mic: [Float]) -> [Float] {
        let ch = CircularAudioBuffer.channelsPerFrame
        let sysFrames = system.count / ch
        let micFrames = mic.count / ch
        let frames = max(sysFrames, micFrames)
        guard frames > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: frames * 2) { buffer, count in
            for f in 0..<frames {
                let sysMono: Float = f < sysFrames ? (system[f * ch] + system[f * ch + 1]) * 0.5 : 0
                let micMono: Float = f < micFrames ? (mic[f * ch] + mic[f * ch + 1]) * 0.5 : 0
                buffer[f * 2] = sysMono
                buffer[f * 2 + 1] = micMono
            }
            count = frames * 2
        }
    }

    private static func mixStereo(_ system: [Float], _ mic: [Float]) -> [Float] {
        let ch = CircularAudioBuffer.channelsPerFrame
        let sysFrames = system.count / ch
        let micFrames = mic.count / ch
        let frames = max(sysFrames, micFrames)
        guard frames > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: frames * 2) { buffer, count in
            for f in 0..<frames {
                let sysL: Float = f < sysFrames ? system[f * ch] : 0
                let sysR: Float = f < sysFrames ? system[f * ch + 1] : 0
                let micL: Float = f < micFrames ? mic[f * ch] : 0
                let micR: Float = f < micFrames ? mic[f * ch + 1] : 0
                buffer[f * 2] = sysL + micL
                buffer[f * 2 + 1] = sysR + micR
            }
            count = frames * 2
        }
    }
}
