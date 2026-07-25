import Foundation

struct SourceOutputSpan: Equatable, Sendable {
    let source: CaptureFrameRange
    let outputStart: CaptureFrame

    var outputEnd: CaptureFrame { outputStart + CaptureFrame(source.count) }
}

struct RecordingSelectionTimeline: Equatable, Sendable {
    struct PauseEdit: Equatable, Sendable {
        var out: CaptureFrame
        var `in`: CaptureFrame
        var inPinnedToNow: Bool
        let minimumOut: CaptureFrame
    }

    private(set) var ranges: [CaptureFrameRange] = []
    private(set) var liveRange: CaptureFrameRange?
    private(set) var pauseEdit: PauseEdit?

    mutating func start(with initial: CaptureFrameRange) {
        ranges = []
        liveRange = initial
        pauseEdit = nil
    }

    mutating func extendLive(to frame: CaptureFrame) {
        guard var liveRange else { return }
        liveRange.end = max(liveRange.end, frame)
        self.liveRange = liveRange
    }

    mutating func rebaseEmptyLive(at frame: CaptureFrame) {
        guard ranges.isEmpty, let liveRange, liveRange.isEmpty else { return }
        self.liveRange = CaptureFrameRange(frame, frame)
    }

    mutating func closeLive(at frame: CaptureFrame) {
        extendLive(to: frame)
        if let liveRange, !liveRange.isEmpty {
            ranges.append(liveRange)
            ranges = Self.coalesced(ranges)
        }
        liveRange = nil
    }

    mutating func beginLive(at frame: CaptureFrame) {
        guard liveRange == nil, pauseEdit == nil else { return }
        liveRange = CaptureFrameRange(frame, frame)
    }

    mutating func pause(at frame: CaptureFrame) {
        closeLive(at: frame)
        pauseEdit = PauseEdit(
            out: ranges.last?.end ?? frame,
            in: frame,
            inPinnedToNow: true,
            minimumOut: ranges.last?.start ?? frame
        )
    }

    mutating func updatePause(out: CaptureFrame? = nil, in newIn: CaptureFrame? = nil,
                              now: CaptureFrame, visible: CaptureFrameRange) {
        guard var pauseEdit else { return }
        if pauseEdit.inPinnedToNow { pauseEdit.in = now }
        if let out {
            pauseEdit.out = max(
                max(visible.start, pauseEdit.minimumOut),
                min(out, pauseEdit.in)
            )
        }
        if let newIn {
            pauseEdit.inPinnedToNow = false
            pauseEdit.in = min(now, max(newIn, pauseEdit.out))
        }
        self.pauseEdit = pauseEdit
    }

    mutating func advancePaused(to now: CaptureFrame) {
        guard var pauseEdit else { return }
        if pauseEdit.inPinnedToNow { pauseEdit.in = now }
        self.pauseEdit = pauseEdit
    }

    mutating func resume(at frame: CaptureFrame) {
        guard pauseEdit != nil else { return }
        ranges = selectedRanges(at: frame)
        pauseEdit = nil
        liveRange = CaptureFrameRange(frame, frame)
    }

    mutating func stop(at frame: CaptureFrame) {
        if pauseEdit != nil {
            ranges = selectedRanges(at: frame)
            pauseEdit = nil
        } else {
            closeLive(at: frame)
        }
        liveRange = nil
    }

    func selectedRanges(at now: CaptureFrame) -> [CaptureFrameRange] {
        var result = ranges
        if let liveRange, !liveRange.isEmpty {
            result.append(liveRange)
        }
        guard var pauseEdit else { return Self.coalesced(result) }
        if pauseEdit.inPinnedToNow { pauseEdit.in = now }

        if !result.isEmpty {
            result[result.count - 1].end = max(
                result[result.count - 1].start,
                pauseEdit.out
            )
            if result[result.count - 1].isEmpty { result.removeLast() }
        }
        if pauseEdit.in < now {
            result.append(CaptureFrameRange(pauseEdit.in, now))
        }
        return Self.coalesced(result)
    }

    func outputSpans(at now: CaptureFrame) -> [SourceOutputSpan] {
        var output: CaptureFrame = 0
        return selectedRanges(at: now).map { range in
            defer { output += CaptureFrame(range.count) }
            return SourceOutputSpan(source: range, outputStart: output)
        }
    }

    func selectedSlices(from cursor: CaptureFrame, to cutoff: CaptureFrame,
                        at now: CaptureFrame) -> [CaptureFrameRange] {
        guard cutoff > cursor else { return [] }
        return selectedRanges(at: now).compactMap { selected in
            let start = max(cursor, selected.start)
            let end = min(cutoff, selected.end)
            return end > start ? CaptureFrameRange(start, end) : nil
        }
    }

    static func coalesced(_ input: [CaptureFrameRange]) -> [CaptureFrameRange] {
        let sorted = input.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var result: [CaptureFrameRange] = []
        for range in sorted {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

struct FinalizedRecordingDescriptor: Sendable {
    struct Fingerprint: Equatable, Sendable {
        let size: UInt64
        let modificationDate: Date
    }

    var recording: RecordingInfo
    let spans: [SourceOutputSpan]
    let split: Bool
    let format: AudioOutputFormat
    let quality: AudioQuality
    let micAdvanceFrames: Int
    let fingerprint: Fingerprint

    var sourceStart: CaptureFrame? { spans.first?.source.start }
    var sourceEnd: CaptureFrame? { spans.last?.source.end }
    var outputFrames: CaptureFrame { spans.last?.outputEnd ?? 0 }
}

struct FinalizedBoundaryEditPlan: Equatable {
    let prefixRange: CaptureFrameRange?
    let originalCrop: ClosedRange<Double>?
    let suffixRange: CaptureFrameRange?

    init(selection: CaptureFrameRange, descriptor: FinalizedRecordingDescriptor) {
        guard let sourceStart = descriptor.sourceStart,
              let sourceEnd = descriptor.sourceEnd else {
            prefixRange = nil
            originalCrop = nil
            suffixRange = nil
            return
        }

        prefixRange = selection.start < sourceStart
            ? CaptureFrameRange(selection.start, min(selection.end, sourceStart))
            : nil
        suffixRange = selection.end > sourceEnd
            ? CaptureFrameRange(max(selection.start, sourceEnd), selection.end)
            : nil

        let cropStart = Self.outputFrame(
            for: max(selection.start, sourceStart),
            spans: descriptor.spans,
            trimmingStart: true
        )
        let cropEnd = Self.outputFrame(
            for: min(selection.end, sourceEnd),
            spans: descriptor.spans,
            trimmingStart: false
        )
        if cropEnd > cropStart {
            originalCrop = (
                Double(cropStart) / AudioConstants.sampleRate
            )...(
                Double(cropEnd) / AudioConstants.sampleRate
            )
        } else {
            originalCrop = nil
        }
    }

    private static func outputFrame(for sourceFrame: CaptureFrame,
                                    spans: [SourceOutputSpan],
                                    trimmingStart: Bool) -> CaptureFrame {
        for span in spans {
            if sourceFrame < span.source.start {
                return trimmingStart ? span.outputStart : max(0, span.outputStart)
            }
            if sourceFrame <= span.source.end {
                return span.outputStart + max(0, min(
                    CaptureFrame(span.source.count),
                    sourceFrame - span.source.start
                ))
            }
        }
        return spans.last?.outputEnd ?? 0
    }
}
