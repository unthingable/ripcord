@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.vibe.ripcord", category: "LiveTranscript")

/// Manages streaming ASR for live transcript output over a socket.
///
/// Feeds audio from CoreAudio callbacks (via a non-RT handoff queue) to one or two
/// `SlidingWindowAsrManager` instances, converts token timings to JSONL, and broadcasts
/// via a `TranscriptSocketServer`.
final class LiveTranscriptStream: @unchecked Sendable {
    private let socketServer: TranscriptSocketServer

    // Streaming ASR managers (actors — must be called from async context)
    // Protected by managerLock when read from flushQueue.
    private var systemManager: SlidingWindowAsrManager?
    private var micManager: SlidingWindowAsrManager?

    // Pending managers during hot-swap reconfigure (fed in parallel with active managers)
    private var pendingSystemManager: SlidingWindowAsrManager?
    private var pendingMicManager: SlidingWindowAsrManager?

    // Protects manager pointer reads/writes between flushQueue and async contexts
    private let managerLock = NSLock()

    // Consumer tasks
    private var systemConsumerTask: Task<Void, Never>?
    private var micConsumerTask: Task<Void, Never>?

    // Pending sample handoff from RT threads (mirrors RecordingManager's pattern)
    private let pendingLock = NSLock()
    private var pendingSystemSamples: [Float] = []
    private var pendingMicSamples: [Float] = []

    // Flush timer — drains pending samples and feeds ASR managers
    private var flushTimer: DispatchSourceTimer?
    private let flushQueue = DispatchQueue(label: "com.vibe.ripcord.livetranscript.flush")

    // In-process word stream for UI consumption
    private var wordContinuation: AsyncStream<TranscriptWord>.Continuation?
    private(set) var wordStream: AsyncStream<TranscriptWord>?

    // Deduplication: track last emitted word end time per source (full-chunk, monotonic)
    // Protected by updateLock (accessed from sys + mic consumer Tasks concurrently)
    private var lastEmittedEnd: [String: TimeInterval] = [:]

    // Deduplication for hypothesis words (rewindable — reset when full-chunk arrives)
    private var lastHypothesisEnd: [String: TimeInterval] = [:]

    // Confirmation tracking: end time of last confirmed update per source
    private var confirmedEnd: [String: TimeInterval] = [:]

    // Serializes handleUpdate / emitWord across sys + mic consumer Tasks
    private let updateLock = NSLock()

    // Timestamp alignment — shared epoch for both streams
    private let startDate = Date()
    private var systemFirstSampleDate: Date?
    private var micFirstSampleDate: Date?

    private static let bufferCapacity: AVAudioFrameCount = 4800  // 100ms at 48kHz

    init(socketServer: TranscriptSocketServer) {
        self.socketServer = socketServer

        // Create in-process word stream for UI consumption
        var continuation: AsyncStream<TranscriptWord>.Continuation!
        let stream = AsyncStream<TranscriptWord> { continuation = $0 }
        self.wordStream = stream
        self.wordContinuation = continuation
    }

    // MARK: - Lifecycle

    func start(
        chunkSeconds: Double = 3.0,
        rightContextSeconds: Double = 1.0,
        minContextForConfirmation: Double = 5.0,
        confirmationThreshold: Double = 0.65
    ) async throws {
        let config = SlidingWindowAsrConfig(
            chunkSeconds: chunkSeconds,
            hypothesisChunkSeconds: max(0.5, chunkSeconds / 2),
            leftContextSeconds: chunkSeconds,
            rightContextSeconds: rightContextSeconds,
            minContextForConfirmation: minContextForConfirmation,
            confirmationThreshold: confirmationThreshold
        )

        // Reset state from any prior stream
        updateLock.withLock {
            lastEmittedEnd.removeAll()
            lastHypothesisEnd.removeAll()
            confirmedEnd.removeAll()
            systemFirstSampleDate = nil
            micFirstSampleDate = nil
        }

        // Create managers
        let sysMgr = SlidingWindowAsrManager(config: config)
        let micMgr = SlidingWindowAsrManager(config: config)
        systemManager = sysMgr
        micManager = micMgr

        // Start consuming transcription updates BEFORE feeding audio
        // (transcriptionUpdates must be accessed exactly once per manager)
        systemConsumerTask = Task { [weak self] in
            for await update in await sysMgr.transcriptionUpdates {
                self?.handleUpdate(update, source: "sys")
            }
        }
        micConsumerTask = Task { [weak self] in
            for await update in await micMgr.transcriptionUpdates {
                self?.handleUpdate(update, source: "mic")
            }
        }

        // Initialize models and start recognition
        try await sysMgr.start(source: .system)
        try await micMgr.start(source: .microphone)

        // Start flush timer (50ms cadence, matching RecordingManager)
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.flushPendingSamples()
        }
        timer.resume()
        flushTimer = timer

        logger.info("Live transcript stream started")
    }

    /// Hot-swap reconfigure: starts new managers in parallel with old ones, feeds audio to both,
    /// then atomically swaps once new managers are ready. No gap in coverage.
    func reconfigure(
        chunkSeconds: Double,
        rightContextSeconds: Double,
        minContextForConfirmation: Double = 5.0,
        confirmationThreshold: Double = 0.65
    ) async throws {
        let config = SlidingWindowAsrConfig(
            chunkSeconds: chunkSeconds,
            hypothesisChunkSeconds: max(0.5, chunkSeconds / 2),
            leftContextSeconds: chunkSeconds,
            rightContextSeconds: rightContextSeconds,
            minContextForConfirmation: minContextForConfirmation,
            confirmationThreshold: confirmationThreshold
        )

        // 1. Create pending managers and make them visible to flushPendingSamples
        let newSysMgr = SlidingWindowAsrManager(config: config)
        let newMicMgr = SlidingWindowAsrManager(config: config)
        managerLock.withLock {
            pendingSystemManager = newSysMgr
            pendingMicManager = newMicMgr
        }

        // 2. Start new managers — old managers continue processing during this await
        try await newSysMgr.start(source: .system)
        try await newMicMgr.start(source: .microphone)

        // 3. Capture old managers for cleanup
        let oldSysMgr = systemManager
        let oldMicMgr = micManager
        let oldSysTask = systemConsumerTask
        let oldMicTask = micConsumerTask

        // 4. Create new consumer tasks
        let newSysTask = Task { [weak self] in
            for await update in await newSysMgr.transcriptionUpdates {
                self?.handleUpdate(update, source: "sys")
            }
        }
        let newMicTask = Task { [weak self] in
            for await update in await newMicMgr.transcriptionUpdates {
                self?.handleUpdate(update, source: "mic")
            }
        }

        // 5. Atomic swap: promote pending to active, reset state
        managerLock.withLock {
            systemManager = newSysMgr
            micManager = newMicMgr
            pendingSystemManager = nil
            pendingMicManager = nil
        }
        systemConsumerTask = newSysTask
        micConsumerTask = newMicTask

        // Reset deduplication, confirmation, and timestamp alignment for new managers
        updateLock.withLock {
            lastEmittedEnd.removeAll()
            lastHypothesisEnd.removeAll()
            confirmedEnd.removeAll()
            systemFirstSampleDate = nil
            micFirstSampleDate = nil
        }

        // 6. Drain old managers (fire-and-forget — non-blocking cleanup)
        oldSysTask?.cancel()
        oldMicTask?.cancel()
        if let oldSys = oldSysMgr {
            Task { _ = try? await oldSys.finish() }
        }
        if let oldMic = oldMicMgr {
            Task { _ = try? await oldMic.finish() }
        }

        logger.info("Live transcript stream reconfigured (hot-swap): chunk=\(chunkSeconds)s, lookahead=\(rightContextSeconds)s")
    }

    func stop() async {
        // Stop flush timer
        flushTimer?.cancel()
        flushTimer = nil

        // Finish ASR managers
        if let sys = systemManager {
            _ = try? await sys.finish()
        }
        if let mic = micManager {
            _ = try? await mic.finish()
        }

        // Cancel consumer tasks
        systemConsumerTask?.cancel()
        micConsumerTask?.cancel()
        systemConsumerTask = nil
        micConsumerTask = nil

        managerLock.withLock {
            systemManager = nil
            micManager = nil
            pendingSystemManager = nil
            pendingMicManager = nil
        }

        // Finish in-process word stream
        wordContinuation?.finish()
        wordContinuation = nil

        // Clear pending buffers
        pendingLock.withLock {
            pendingSystemSamples.removeAll()
            pendingMicSamples.removeAll()
        }

        logger.info("Live transcript stream stopped")
    }

    // MARK: - Audio feeding (called from CoreAudio RT threads)

    /// Called from RecordingManager.handleSystemSamples on the CoreAudio RT thread.
    /// Only appends to a pending array behind a lock — no allocation, no actor calls.
    func feedSystemAudio(_ samples: [Float]) {
        pendingLock.withLock {
            pendingSystemSamples.append(contentsOf: samples)
        }
    }

    /// Called from RecordingManager.handleMicSamples on the CoreAudio RT thread.
    func feedMicAudio(_ samples: [Float]) {
        pendingLock.withLock {
            pendingMicSamples.append(contentsOf: samples)
        }
    }

    // MARK: - Flush (runs on flushQueue — NOT a real-time thread)

    private var flushCount = 0

    private func flushPendingSamples() {
        // Drain pending samples under lock
        let (sysSamples, micSamples) = pendingLock.withLock { () -> ([Float], [Float]) in
            let sys = pendingSystemSamples
            let mic = pendingMicSamples
            pendingSystemSamples.removeAll(keepingCapacity: true)
            pendingMicSamples.removeAll(keepingCapacity: true)
            return (sys, mic)
        }

        // Snapshot manager pointers under lock (hot-swap may be in progress)
        let (sysMgr, micMgr, pendingSys, pendingMic) = managerLock.withLock {
            (systemManager, micManager, pendingSystemManager, pendingMicManager)
        }

        // DIAG: log every ~5s (100 flushes at 50ms)
        flushCount += 1
        if flushCount % 100 == 0 {
            logger.error("flush #\(self.flushCount): sys=\(sysSamples.count) mic=\(micSamples.count) sysMgr=\(sysMgr != nil) micMgr=\(micMgr != nil)")
        }

        // Feed system audio to active + pending managers
        if !sysSamples.isEmpty {
            // Record first-sample date under updateLock — handleUpdate reads it under the same lock
            updateLock.withLock { if systemFirstSampleDate == nil { systemFirstSampleDate = Date() } }
            if let mgr = sysMgr { Self.feedManager(mgr, samples: sysSamples) }
            if let mgr = pendingSys { Self.feedManager(mgr, samples: sysSamples) }
        }

        // Feed mic audio to active + pending managers
        if !micSamples.isEmpty {
            updateLock.withLock { if micFirstSampleDate == nil { micFirstSampleDate = Date() } }
            if let mgr = micMgr { Self.feedManager(mgr, samples: micSamples) }
            if let mgr = pendingMic { Self.feedManager(mgr, samples: micSamples) }
        }
    }

    private static let bufferFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioConstants.sampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Sends samples to a manager in a Task. Buffer is created inside the Task
    /// to satisfy Swift 6 sending requirements.
    private static func feedManager(_ manager: SlidingWindowAsrManager, samples: [Float]) {
        Task {
            let frameCount = AVAudioFrameCount(samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: frameCount),
                  let channelData = buffer.floatChannelData else { return }
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
            buffer.frameLength = frameCount
            await manager.streamAudio(buffer)
        }
    }

    // MARK: - Transcription update handling

    private var sysUpdateCount = 0

    private func handleUpdate(_ update: SlidingWindowTranscriptionUpdate, source: String) {
        let timings = update.tokenTimings
        if source == "sys" {
            sysUpdateCount += 1
            logger.error("sys update #\(self.sysUpdateCount): timings=\(timings.count) text=\(update.text.prefix(60))")
        }
        guard !timings.isEmpty else { return }

        updateLock.withLock {
            let sourceFirstDate: Date? = source == "sys" ? systemFirstSampleDate : micFirstSampleDate
            let timeOffset = sourceFirstDate?.timeIntervalSince(startDate) ?? 0

            let isHypothesis = update.isHypothesis

            // Full-chunk updates: retract prior hypothesis words before emitting
            if !isHypothesis {
                let retractFrom = lastEmittedEnd[source] ?? 0
                if let hypEnd = lastHypothesisEnd[source], hypEnd > retractFrom {
                    socketServer.broadcast(
                        "{\"type\":\"retract\",\"src\":\"\(source)\",\"from\":\(String(format: "%.2f", retractFrom))}"
                    )
                }
                lastHypothesisEnd[source] = nil
            }

            // Update confirmed-through watermark (full-chunk only)
            if !isHypothesis && update.isConfirmed, let lastTiming = timings.last {
                let newEnd = lastTiming.endTime + timeOffset
                let prev = confirmedEnd[source] ?? 0
                if newEnd > prev {
                    confirmedEnd[source] = newEnd
                    socketServer.broadcast(
                        "{\"type\":\"confirm\",\"src\":\"\(source)\",\"end\":\(String(format: "%.2f", newEnd))}"
                    )
                }
            }

            // Join sub-word tokens into words.
            // Parakeet SentencePiece: tokens starting with a space begin a new word.
            var wordStart: TimeInterval = timings[0].startTime
            var wordEnd: TimeInterval = timings[0].endTime
            var wordText = ""

            for timing in timings {
                let token = timing.token
                let startsNewWord = token.hasPrefix(" ") && !wordText.isEmpty

                if startsNewWord {
                    emitWordLocked(
                        wordText, start: wordStart + timeOffset, end: wordEnd + timeOffset,
                        source: source, isHypothesis: isHypothesis
                    )
                    wordText = String(token.dropFirst())
                    wordStart = timing.startTime
                    wordEnd = timing.endTime
                } else {
                    let piece = token.hasPrefix(" ") ? String(token.dropFirst()) : token
                    wordText += piece
                    wordEnd = timing.endTime
                }
            }

            if !wordText.isEmpty {
                emitWordLocked(
                    wordText, start: wordStart + timeOffset, end: wordEnd + timeOffset,
                    source: source, isHypothesis: isHypothesis
                )
            }
        }
    }

    /// Must be called under updateLock.
    private func emitWordLocked(
        _ word: String, start: TimeInterval, end: TimeInterval,
        source: String, isHypothesis: Bool = false
    ) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isHypothesis {
            // Hypothesis dedup: skip if already emitted a hypothesis past this point
            if let lastHypEnd = lastHypothesisEnd[source], end <= lastHypEnd + 0.01 {
                return
            }
            // Also skip if full-chunk output already covers this range
            if let lastEnd = lastEmittedEnd[source], end <= lastEnd + 0.01 {
                return
            }
            lastHypothesisEnd[source] = end
        } else {
            // Full-chunk dedup: skip words already covered
            if let lastEnd = lastEmittedEnd[source], end <= lastEnd + 0.01 {
                return
            }
            lastEmittedEnd[source] = end
        }

        let confEnd = confirmedEnd[source] ?? 0

        // Broadcast to socket clients
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        var line = """
            {"t":\(String(format: "%.2f", start)),"end":\(String(format: "%.2f", end)),\
            "word":"\(escaped)","src":"\(source)","conf":\(String(format: "%.2f", confEnd))
            """
        if isHypothesis {
            line += ",\"hyp\":true}"
        } else {
            line += "}"
        }
        socketServer.broadcast(line)

        // Yield to in-process stream for UI
        wordContinuation?.yield(TranscriptWord(
            word: trimmed, start: start, end: end, source: source,
            confirmedThrough: confEnd, isHypothesis: isHypothesis
        ))
    }
}
