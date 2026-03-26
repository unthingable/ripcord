import AVFoundation
import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.vibe.ripcord", category: "LiveTranscript")

/// Manages streaming ASR for live transcript output over a socket.
///
/// Feeds audio from CoreAudio callbacks (via a non-RT handoff queue) to one or two
/// `StreamingAsrManager` instances, converts token timings to JSONL, and broadcasts
/// via a `TranscriptSocketServer`.
final class LiveTranscriptStream: @unchecked Sendable {
    private let socketServer: TranscriptSocketServer
    private let audioFormat: AVAudioFormat

    // Streaming ASR managers (actors — must be called from async context)
    private var systemManager: StreamingAsrManager?
    private var micManager: StreamingAsrManager?

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

    // Deduplication: track last emitted word end time per source
    private var lastEmittedEnd: [String: TimeInterval] = [:]

    // Timestamp alignment — shared epoch for both streams
    private let startDate = Date()
    private var systemFirstSampleDate: Date?
    private var micFirstSampleDate: Date?

    private static let bufferCapacity: AVAudioFrameCount = 4800  // 100ms at 48kHz

    init(socketServer: TranscriptSocketServer) {
        self.socketServer = socketServer
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioConstants.sampleRate,
            channels: 1,
            interleaved: false
        )!

        // Create in-process word stream for UI consumption
        var continuation: AsyncStream<TranscriptWord>.Continuation!
        let stream = AsyncStream<TranscriptWord> { continuation = $0 }
        self.wordStream = stream
        self.wordContinuation = continuation
    }

    // MARK: - Lifecycle

    func start(
        chunkSeconds: Double = 3.0,
        rightContextSeconds: Double = 1.0
    ) async throws {
        let config = StreamingAsrConfig(
            chunkSeconds: chunkSeconds,
            hypothesisChunkSeconds: max(0.5, chunkSeconds / 2),
            leftContextSeconds: chunkSeconds,
            rightContextSeconds: rightContextSeconds,
            minContextForConfirmation: chunkSeconds * 2,
            confirmationThreshold: 0.65
        )

        // Create managers
        let sysMgr = StreamingAsrManager(config: config)
        let micMgr = StreamingAsrManager(config: config)
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

    /// Restart ASR managers with new config without interrupting audio feeding.
    /// Pending audio buffers and flush timer stay alive — no gap in coverage.
    func reconfigure(
        chunkSeconds: Double,
        rightContextSeconds: Double
    ) async throws {
        // Stop old managers and consumer tasks
        systemConsumerTask?.cancel()
        micConsumerTask?.cancel()
        if let sys = systemManager { _ = try? await sys.finish() }
        if let mic = micManager { _ = try? await mic.finish() }

        // Create new managers with updated config
        let config = StreamingAsrConfig(
            chunkSeconds: chunkSeconds,
            hypothesisChunkSeconds: max(0.5, chunkSeconds / 2),
            leftContextSeconds: chunkSeconds,
            rightContextSeconds: rightContextSeconds,
            minContextForConfirmation: chunkSeconds * 2,
            confirmationThreshold: 0.65
        )

        let sysMgr = StreamingAsrManager(config: config)
        let micMgr = StreamingAsrManager(config: config)
        systemManager = sysMgr
        micManager = micMgr

        // Start new consumer tasks
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

        // Reset deduplication and timestamp alignment for new managers
        lastEmittedEnd.removeAll()
        systemFirstSampleDate = nil
        micFirstSampleDate = nil

        try await sysMgr.start(source: .system)
        try await micMgr.start(source: .microphone)

        logger.info("Live transcript stream reconfigured: chunk=\(chunkSeconds)s, lookahead=\(rightContextSeconds)s")
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

        systemManager = nil
        micManager = nil

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

    private func flushPendingSamples() {
        // Drain pending samples under lock
        let (sysSamples, micSamples) = pendingLock.withLock { () -> ([Float], [Float]) in
            let sys = pendingSystemSamples
            let mic = pendingMicSamples
            pendingSystemSamples.removeAll(keepingCapacity: true)
            pendingMicSamples.removeAll(keepingCapacity: true)
            return (sys, mic)
        }

        // Feed system audio
        if !sysSamples.isEmpty, let manager = systemManager {
            if systemFirstSampleDate == nil { systemFirstSampleDate = Date() }
            let fmt = audioFormat
            let samples = sysSamples
            Task { await Self.feedSamples(samples, format: fmt, to: manager) }
        }

        // Feed mic audio
        if !micSamples.isEmpty, let manager = micManager {
            if micFirstSampleDate == nil { micFirstSampleDate = Date() }
            let fmt = audioFormat
            let samples = micSamples
            Task { await Self.feedSamples(samples, format: fmt, to: manager) }
        }
    }

    /// Creates an AVAudioPCMBuffer from samples and feeds it to the ASR manager.
    /// Runs inside a Task to satisfy actor isolation requirements.
    private static func feedSamples(
        _ samples: [Float], format: AVAudioFormat, to manager: StreamingAsrManager
    ) async {
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        guard let channelData = buffer.floatChannelData else { return }
        samples.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: samples.count)
        }
        buffer.frameLength = frameCount
        await manager.streamAudio(buffer)
    }

    // MARK: - Transcription update handling

    private func handleUpdate(_ update: StreamingTranscriptionUpdate, source: String) {
        let sourceFirstDate: Date?
        if source == "sys" {
            sourceFirstDate = systemFirstSampleDate
        } else {
            sourceFirstDate = micFirstSampleDate
        }
        let timeOffset = sourceFirstDate?.timeIntervalSince(startDate) ?? 0

        // Join sub-word tokens into words.
        // Parakeet SentencePiece: tokens starting with a space begin a new word.
        let timings = update.tokenTimings
        guard !timings.isEmpty else { return }

        var wordStart: TimeInterval = timings[0].startTime
        var wordEnd: TimeInterval = timings[0].endTime
        var wordText = ""

        for timing in timings {
            let token = timing.token
            let startsNewWord = token.hasPrefix(" ") && !wordText.isEmpty

            if startsNewWord {
                emitWord(
                    wordText, start: wordStart + timeOffset, end: wordEnd + timeOffset,
                    source: source
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
            emitWord(
                wordText, start: wordStart + timeOffset, end: wordEnd + timeOffset,
                source: source
            )
        }
    }

    private func emitWord(_ word: String, start: TimeInterval, end: TimeInterval, source: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Deduplicate: skip words already covered by a previous update for this source
        if let lastEnd = lastEmittedEnd[source], end <= lastEnd + 0.01 {
            return
        }
        lastEmittedEnd[source] = end

        // Broadcast to socket clients
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let line = """
            {"t":\(String(format: "%.2f", start)),"end":\(String(format: "%.2f", end)),\
            "word":"\(escaped)","src":"\(source)"}
            """
        socketServer.broadcast(line)

        // Yield to in-process stream for UI
        wordContinuation?.yield(TranscriptWord(word: trimmed, start: start, end: end, source: source))
    }
}
