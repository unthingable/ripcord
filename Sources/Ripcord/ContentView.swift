import AVFoundation
import SwiftUI
import TranscribeKit
import UniformTypeIdentifiers

struct ContentView: View {
    private enum WaveformDragHandle {
        case capture, pausedOut, pausedIn, editStart, editEnd
    }

    @Bindable var manager: RecordingManager

    @State private var transcribeTarget: RecordingInfo?
    @State private var pendingTranscriptionConfig = TranscriptionConfig()
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showFileTranscribePopover = false
    @State private var fileTranscribeURL: URL?
    @State private var renamingURL: URL?
    @State private var renameText: String = ""
    @AppStorage(SettingsKey.mainPanelRecentsHeight) private var recentsHeight: Double = 160
    @State private var dragStartHeight: Double?
    @State private var resizeHovering = false
    @State private var micDevicePickerHovered = false
    @State private var micChannelPickerHovered = false
    @State private var waveformDragHandle: WaveformDragHandle?
    // Stored outside @State to avoid MainActor-isolation issues in NotificationCenter closures
    private static nonisolated(unsafe) var settingsCloseObserver: NSObjectProtocol?

    var body: some View {
        mainContent
            .padding(8)
            .frame(width: 320)
            .background(Color(nsColor: .windowBackgroundColor))
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .overlay(alignment: .bottom) {
                if !manager.recentRecordings.isEmpty {
                    resizeHandle
                }
            }
            .onAppear {
                setupGlobalHotkey()
                manager.refreshSystemMicMode()
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status
            statusSection

            // Capture duration scrubber with level meters
            if manager.state == .buffering || manager.state == .recording || manager.state == .paused {
                captureSlider
                    .onAppear { manager.startWaveformTimer() }
                    .onDisappear { manager.stopWaveformTimer() }
            }

            // Recording name field
            if manager.state == .buffering || manager.state == .recording || manager.state == .paused {
                nameField
            }

            // Record / Stop button
            recordButton

            Divider()

            // Config summary
            configSummary

            micRow
            micModeWarning

            // Recent recordings
            if !manager.recentRecordings.isEmpty {
                Divider()
                recentRecordingsSection
            }

            Divider()

            HStack {
                if manager.transcriptionService.modelsLoaded {
                    Button("Transcribe File\u{2026}") {
                        NSApp.activate(ignoringOtherApps: true)
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.wav, .audio, .movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
                        panel.allowsMultipleSelection = false
                        panel.begin { response in
                            guard response == .OK, let url = panel.url else { return }
                            pinMenuBarWindow(true)
                            menuBarWindow?.makeKeyAndOrderFront(nil)
                            fileTranscribeURL = url
                            pendingTranscriptionConfig = manager.transcriptionConfig
                            showFileTranscribePopover = true
                        }
                    }
                    .font(.caption)
                    .disabled(manager.transcriptionService.isTranscribing)
                    .instantPopover(isPresented: $showFileTranscribePopover, arrowEdge: .top) {
                        TranscriptionConfigPopover(config: $pendingTranscriptionConfig) {
                            showFileTranscribePopover = false
                            if let url = fileTranscribeURL {
                                manager.transcribeFile(url, config: pendingTranscriptionConfig)
                                fileTranscribeURL = nil
                            }
                        } onCancel: {
                            showFileTranscribePopover = false
                            fileTranscribeURL = nil
                        }
                    }
                    .onChange(of: showFileTranscribePopover) { _, showing in
                        if !showing { pinMenuBarWindow(false) }
                    }
                } else if case .loadingModels = manager.transcriptionService.state {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Loading models…")
                            .font(.caption2)
                    }
                } else if case .downloadingModels(let progress) = manager.transcriptionService.state {
                    HStack(spacing: 4) {
                        ProgressView(value: progress).frame(width: 60)
                        Text("Downloading…")
                            .font(.caption2)
                    }
                } else if case .idle = manager.transcriptionService.state {
                    Button("Download Models\u{2026}") {
                        manager.downloadTranscriptionModels()
                    }
                    .font(.caption)
                } else if case .failed = manager.transcriptionService.state {
                    Button("Retry Model Download") {
                        manager.downloadTranscriptionModels()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }

                Spacer()

                Button("Quit") {
                    if manager.state == .recording || manager.state == .paused {
                        manager.stopRecording()
                    }
                    manager.shutdown()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .contentShape(Rectangle())
            .onHover { resizeHovering = $0 }
            .simultaneousGesture(resizeDrag)

            if let error = manager.transcriptionService.lastTranscriptionError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var menuBarWindow: NSWindow? {
        NSApp.windows.first {
            String(describing: type(of: $0)).contains("MenuBarExtraWindow")
        }
    }

    /// Open the Settings window and bring it above the MenuBarExtra panel.
    private func openSettingsWindow() {
        let panel = menuBarWindow
        panel?.close()
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { @Sendable in
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                guard let settings = NSApp.windows.first(where: {
                    $0 != panel && $0.title == "Settings" && $0.isVisible
                }) else { return }
                if let obs = Self.settingsCloseObserver {
                    NotificationCenter.default.removeObserver(obs)
                }
                Self.settingsCloseObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: settings, queue: .main
                ) { @Sendable [weak panel] _ in
                    MainActor.assumeIsolated {
                        if let obs = Self.settingsCloseObserver {
                            NotificationCenter.default.removeObserver(obs)
                            Self.settingsCloseObserver = nil
                        }
                        panel?.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
    }

    /// Pin/unpin the MenuBarExtra window so it doesn't dismiss on focus loss.
    private func pinMenuBarWindow(_ pin: Bool) {
        guard let w = menuBarWindow else { return }
        w.hidesOnDeactivate = !pin
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(statusText)")
            Spacer()
            if manager.liveTranscriptEnabled && manager.liveTranscriptStream != nil {
                Button(action: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "copilot")
                }) {
                    Image(systemName: "text.bubble.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Open Live Transcript")
            }
            Button(action: {
                openSettingsWindow()
            }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Settings")
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .starting: return .gray
        case .buffering: return .green
        case .recording:
            return manager.isSilencePaused ? .red.opacity(0.4) : .red
        case .paused: return .orange
        case .error: return .pink
        }
    }

    private var statusText: String {
        switch manager.state {
        case .starting:
            return "Starting..."
        case .buffering:
            let fill = manager.bufferFillSeconds
            let cap = manager.bufferDurationSeconds
            return fill >= cap
                ? "Buffering (Full - \(formatTime(cap)))"
                : "Buffering (\(formatTime(fill)) / \(formatTime(cap)))"
        case .recording:
            let elapsed = formatTime(Int(manager.recordingElapsed))
            return manager.isSilencePaused
                ? "Recording (\(elapsed)) - Silence"
                : "Recording (\(elapsed))"
        case .paused:
            let elapsed = formatTime(Int(manager.recordingElapsed))
            return "Paused (\(elapsed))"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    // MARK: - Capture Waveform Scrubber

    @ViewBuilder
    private var captureSlider: some View {
        let isRecording = manager.state == .recording
        let isPaused = manager.state == .paused
        let isCapturing = isRecording || isPaused
        let isEditing = manager.isEditingLatestRecording

        VStack(spacing: 4) {
            HStack {
                if isRecording {
                    Text("Recording")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if isPaused {
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Out / In")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if isEditing {
                    Text("Adjust recording")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("Capture: \(formatTime(manager.captureDurationSeconds))")
                        .font(.caption)
                    Spacer()
                    Text("/ \(formatTime(manager.bufferDurationSeconds))")
                        .font(.caption)
                }
                Spacer()
            }

            HStack(spacing: 4) {
                // Waveform with draggable capture handle
                // Left = oldest audio, Right = NOW
                // Everything right of handle = captured
                GeometryReader { geo in
                    let width = geo.size.width
                    let bufMax = Double(max(1, manager.bufferDurationSeconds))
                    // While recording/paused, the handle slides left in lockstep with
                    // recorded elapsed so right-of-handle always reflects total captured
                    // audio (back-record + recorded so far). captureDurationSeconds itself
                    // is not mutated — it stays as the user's back-record preference.
                    let effectiveCapture = isCapturing
                        ? min(bufMax, Double(manager.captureDurationSeconds) + manager.recordingElapsed)
                        : Double(manager.captureDurationSeconds)
                    let captureFraction = effectiveCapture / bufMax
                    let handleX = width * (1 - captureFraction)
                    let visible = isEditing
                        ? (manager.latestRecordingEditVisibleRange ?? manager.visibleCaptureRange)
                        : manager.visibleCaptureRange
                    let pausedRange = manager.pausedSelectionRange
                    let xForFrame: (CaptureFrame) -> CGFloat? = { frame in
                        guard !visible.isEmpty, frame >= visible.start, frame <= visible.end else { return nil }
                        return width * CGFloat(Double(frame - visible.start) / Double(visible.count))
                    }
                    let pausedOutX = pausedRange.flatMap { xForFrame($0.start) }
                    let pausedInX = pausedRange.flatMap { xForFrame($0.end) }
                    let editRange = manager.latestRecordingEditRange
                    let candidateRange = isEditing ? editRange : manager.latestRecordingBoundaryRange
                    let editStartX = candidateRange.flatMap { xForFrame($0.start) }
                    let editEndX = candidateRange.flatMap { xForFrame($0.end) }
                    let amps = isEditing
                        ? (manager.latestRecordingEditWaveformAmplitudes ?? manager.waveformAmplitudes)
                        : manager.waveformAmplitudes
                    let states = isEditing
                        ? (manager.latestRecordingEditWaveformStates ?? manager.waveformBarStates)
                        : manager.waveformBarStates
                    let displayedFilledBarCount = isEditing
                        ? (manager.latestRecordingEditFilledBarCount ?? manager.filledBarCount)
                        : manager.filledBarCount
                    let selectedRanges = manager.recordingSelectedRanges

                    Canvas { context, size in
                        let barWidth: CGFloat = 2
                        let gap: CGFloat = 1
                        let step = barWidth + gap
                        let midY = size.height / 2

                        let totalBars = max(1, Int(size.width / step))
                        let filledBars = min(totalBars, displayedFilledBarCount)
                        let startBar = totalBars - filledBars

                        for i in 0..<filledBars {
                            let x = CGFloat(startBar + i) * step
                            let amp = CGFloat(amps[100 - filledBars + i])
                            let barHeight = max(2, amp * size.height * 0.9)
                            let barState = states[100 - filledBars + i]
                            let frame = visible.start + CaptureFrame(
                                Double(visible.count) * Double((x + barWidth / 2) / max(1, size.width))
                            )
                            let isSelected = selectedRanges.contains {
                                frame >= $0.start && frame < $0.end
                            }
                            let isInsideSession = selectedRanges.first.map {
                                frame >= $0.start && frame <= visible.end
                            } ?? false

                            let color: Color
                            if isCapturing && isInsideSession {
                                color = isSelected ? .red : .orange
                            } else {
                                switch barState {
                                case .recorded:
                                    color = .red
                                case .paused:
                                    color = .orange
                                case .priorRecorded:
                                    color = .red.opacity(0.4)
                                case .priorPaused:
                                    color = .orange.opacity(0.4)
                                case .idle:
                                    if isCapturing {
                                        color = .primary.opacity(0.15)
                                    } else {
                                        let isCaptured = x >= handleX
                                        color = isCaptured ? .accentColor : .primary.opacity(0.15)
                                    }
                                }
                            }

                            let rect = CGRect(
                                x: x,
                                y: midY - barHeight / 2,
                                width: barWidth,
                                height: barHeight
                            )
                            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                        }

                        // The old capture handle stays put while recording. Paused
                        // and finalized-edit states use explicit Out/In boundaries.
                        if !isPaused && !isEditing, handleX >= 0, handleX <= size.width {
                            let handleRect = CGRect(x: handleX - 1, y: 0, width: 2, height: size.height)
                            context.fill(
                                Path(roundedRect: handleRect, cornerRadius: 1),
                                with: .color(.primary.opacity(0.5))
                            )
                        }
                        drawBoundaryHandle(
                            context: &context, size: size,
                            position: pausedOutX, label: "OUT", labelY: 7
                        )
                        drawBoundaryHandle(
                            context: &context, size: size,
                            position: pausedInX, label: "IN", labelY: size.height - 7
                        )
                        drawBoundaryHandle(
                            context: &context, size: size,
                            position: editStartX, label: "START", labelY: 7
                        )
                        drawBoundaryHandle(
                            context: &context, size: size,
                            position: editEndX, label: "END", labelY: size.height - 7
                        )
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let fraction = max(0, min(1, value.location.x / width))
                                let frame = visible.start
                                    + CaptureFrame((Double(visible.count) * fraction).rounded())
                                if waveformDragHandle == nil {
                                    if isPaused {
                                        let selection = pausedRange
                                            ?? CaptureFrameRange(visible.end, visible.end)
                                        if selection.start == selection.end {
                                            guard abs(value.location.x - value.startLocation.x) >= 1 else {
                                                return
                                            }
                                            waveformDragHandle = value.location.x < value.startLocation.x
                                                ? .pausedOut : .pausedIn
                                        } else {
                                            waveformDragHandle = abs(frame - selection.start)
                                                <= abs(frame - selection.end) ? .pausedOut : .pausedIn
                                        }
                                    } else if isEditing, let editRange {
                                        waveformDragHandle = abs(frame - editRange.start)
                                            <= abs(frame - editRange.end) ? .editStart : .editEnd
                                    } else if !isRecording,
                                              let candidateRange = manager.latestRecordingBoundaryRange {
                                        let tolerance = CaptureFrame(
                                            Double(max(1, visible.count)) * 12 / Double(max(1, width))
                                        )
                                        let startDistance = abs(frame - candidateRange.start)
                                        let endDistance = abs(frame - candidateRange.end)
                                        if min(startDistance, endDistance) <= tolerance {
                                            waveformDragHandle = startDistance <= endDistance
                                                ? .editStart : .editEnd
                                        } else {
                                            waveformDragHandle = .capture
                                        }
                                    } else if !isRecording {
                                        waveformDragHandle = .capture
                                    }
                                }
                                switch waveformDragHandle {
                                case .pausedOut:
                                    manager.updatePausedSelection(out: frame)
                                case .pausedIn:
                                    manager.updatePausedSelection(in: frame)
                                case .editStart:
                                    manager.updateLatestRecordingEdit(start: frame)
                                case .editEnd:
                                    manager.updateLatestRecordingEdit(end: frame)
                                case .capture:
                                    let seconds = Int((1 - fraction) * bufMax)
                                    manager.updateCaptureDuration(seconds)
                                case .none:
                                    break
                                }
                            }
                            .onEnded { _ in waveformDragHandle = nil }
                    )
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.05)))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Vertical level meters
                levelMeters
            }
            .frame(height: 44)
        }
    }

    private func drawBoundaryHandle(
        context: inout GraphicsContext,
        size: CGSize,
        position: CGFloat?,
        label: String,
        labelY: CGFloat
    ) {
        guard let position else { return }
        let lineX = max(2, min(size.width - 2, position))
        let line = CGRect(x: lineX - 1.5, y: 0, width: 3, height: size.height)
        context.fill(
            Path(roundedRect: line, cornerRadius: 1.5),
            with: .color(.accentColor)
        )

        let badgeWidth = max(22, CGFloat(label.count * 6 + 8))
        let badgeCenterX = max(
            badgeWidth / 2,
            min(size.width - badgeWidth / 2, lineX)
        )
        let badge = CGRect(
            x: badgeCenterX - badgeWidth / 2,
            y: labelY - 6,
            width: badgeWidth,
            height: 12
        )
        context.fill(
            Path(roundedRect: badge, cornerRadius: 3),
            with: .color(.accentColor)
        )
        context.draw(
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white),
            at: CGPoint(x: badgeCenterX, y: labelY)
        )
    }

    // MARK: - Level Meters

    @ViewBuilder
    private var levelMeters: some View {
        let sysLevel = manager.systemLevel
        let micLevel = manager.micLevel
        HStack(spacing: 2) {
            verticalMeter(level: sysLevel, color: .blue)
            verticalMeter(level: micLevel, color: .cyan)
        }
        .frame(width: 12)
    }

    private func verticalMeter(level: Float, color: Color) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let fill = CGFloat(min(1, level * 2.5)) * h
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(height: fill)
            }
        }
    }

    // MARK: - Name Field

    @ViewBuilder
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Name this recording\u{2026}", text: $manager.recordingName)
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))

            let suggestions = manager.nameSuggestions(for: manager.recordingName)
            if !manager.recordingName.isEmpty && !suggestions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            manager.recordingName = suggestion
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.primary.opacity(0.08)))
                    }
                }
            }
        }
    }

    // MARK: - Record Button

    @ViewBuilder
    private var recordButton: some View {
        if manager.state == .recording {
            HStack(spacing: 8) {
                Button(action: { manager.pauseRecording() }) {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("p", modifiers: [])

                Button(action: { manager.stopRecording() }) {
                    Label("Stop Recording", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: [.command])
            }
        } else if manager.state == .paused {
            HStack(spacing: 8) {
                Button(action: { manager.resumeRecording() }) {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("p", modifiers: [])

                Button(action: { manager.stopRecording() }) {
                    Label("Stop Recording", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: [.command])
            }
        } else if manager.state == .buffering {
            if manager.isEditingLatestRecording {
                HStack(spacing: 8) {
                    Button("Apply") { Task { await manager.applyLatestRecordingEdit() } }
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(manager.isApplyingLatestRecordingEdit)
                    Button("Cancel") { manager.cancelLatestRecordingEdit() }
                        .controlSize(.large)
                        .disabled(manager.isApplyingLatestRecordingEdit)
                }
            } else {
                Button(action: { manager.startRecording() }) {
                    Label("Record", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: [])
                .accessibilityHint("Starts recording, including buffered audio")
            }
        } else if case .error(let msg) = manager.state {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: { Task { await manager.startBuffering() } }) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                if msg.lowercased().contains("permission") || msg.lowercased().contains("privacy") {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Config Summary

    @ViewBuilder
    private var configSummary: some View {
        HStack(spacing: 4) {
            configMenu(
                title: "Buffer",
                value: "\(manager.bufferDurationSeconds / 60) min",
                help: "Buffer duration"
            ) {
                ForEach([60, 300, 600, 900], id: \.self) { seconds in
                    Button {
                        manager.updateBufferDuration(seconds)
                    } label: {
                        let label = "\(seconds / 60) min"
                        if manager.bufferDurationSeconds == seconds {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            }

            Text("\u{2022}")
                .foregroundStyle(.secondary)

            configMenu(
                title: nil,
                value: manager.outputFormat.rawValue,
                help: "Recording format"
            ) {
                ForEach(AudioOutputFormat.allCases) { format in
                    Button {
                        manager.updateOutputFormat(format)
                    } label: {
                        if manager.outputFormat == format {
                            Label(format.rawValue, systemImage: "checkmark")
                        } else {
                            Text(format.rawValue)
                        }
                    }
                }
            }

            Text("\u{2022}")
                .foregroundStyle(.secondary)

            if manager.outputFormat == .wav {
                Text("16-bit")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("WAV records as 16-bit stereo")
            } else {
                configMenu(
                    title: nil,
                    value: manager.audioQuality.label(for: manager.outputFormat),
                    help: "Recording quality"
                ) {
                    ForEach(AudioQuality.allCases) { quality in
                        Button {
                            manager.updateAudioQuality(quality)
                        } label: {
                            let label = quality.label(for: manager.outputFormat)
                            if manager.audioQuality == quality {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }
            }
        }
        .font(.system(size: 10))
        .disabled(manager.state == .recording || manager.state == .paused)
    }

    @ViewBuilder
    private func configMenu<Items: View>(
        title: String?,
        value: String,
        help: String,
        @ViewBuilder items: @escaping () -> Items
    ) -> some View {
        ConfigSummaryMenu(title: title, value: value, help: help, items: items)
    }

    // MARK: - Per-device input gain (dB)

    @ViewBuilder
    private func inputControls(for device: AudioInputDevice) -> some View {
        MicInputControls(manager: manager, device: device)
    }

    // MARK: - Channel-mode picker (multi-channel mic devices)

    @ViewBuilder
    private func channelModePicker(for device: AudioInputDevice) -> some View {
        let mode = manager.currentMicChannelMode() ?? .defaultForMultiChannel
        let chipLabel: String = {
            switch mode {
            case .stereo:               return "1/2"
            case .mono(let ch):         return "M\(ch)"
            }
        }()

        Menu {
            Button {
                Task { await manager.updateMicChannelMode(.stereo, forUID: device.uid) }
            } label: {
                if mode == .stereo {
                    Label("Stereo (1/2)", systemImage: "checkmark")
                } else {
                    Text("Stereo (1/2)")
                }
            }
            Divider()
            ForEach(1...device.inputChannelCount, id: \.self) { ch in
                Button {
                    Task { await manager.updateMicChannelMode(.mono(channel: ch), forUID: device.uid) }
                } label: {
                    if mode == .mono(channel: ch) {
                        Label("Mono (\(ch))", systemImage: "checkmark")
                    } else {
                        Text("Mono (\(ch))")
                    }
                }
            }
        } label: {
            Text(chipLabel)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(micChannelPickerHovered ? 0.24 : 0.15))
                )
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mic input channels: stereo pair, or single channel as mono.")
        .opacity(manager.micEnabled ? 1 : 0.4)
        .onHover { micChannelPickerHovered = $0 }
    }

    // MARK: - Mic Row (toggle + device picker)

    @ViewBuilder
    private var micRow: some View {
        let devices = manager.deviceEnumerator.inputDevices
        let selectedUID = manager.selectedMicUID
        let selectedLabel: String = {
            if let uid = selectedUID {
                if let device = devices.first(where: { $0.uid == uid }) {
                    return device.name
                }
                return "\(uid) (Disconnected)"
            }
            return "System Default"
        }()

        HStack(spacing: 6) {
            Menu {
                Button {
                    Task { await manager.updateSelectedMic(nil) }
                } label: {
                    if selectedUID == nil {
                        Label("System Default", systemImage: "checkmark")
                    } else {
                        Text("System Default")
                    }
                }

                Divider()

                ForEach(devices) { device in
                    Button {
                        Task { await manager.updateSelectedMic(device.uid) }
                    } label: {
                        if selectedUID == device.uid {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }

                // Show disconnected entry if saved UID is not in current list
                if let uid = selectedUID,
                   !devices.contains(where: { $0.uid == uid }) {
                    Divider()
                    Button { } label: {
                        Label("\(uid) (Disconnected)", systemImage: "checkmark")
                    }
                    .disabled(true)
                }
            } label: {
                HStack {
                    Label(selectedLabel, systemImage: "mic")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.primary.opacity(micDevicePickerHovered ? 0.08 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(manager.micEnabled ? 1 : 0.4)
            .onHover { micDevicePickerHovered = $0 }

            // Channel-mode picker: only visible when the selected device exposes
            // more than one input channel. For a single-channel device there's
            // nothing to choose.
            if let device = manager.currentSelectedMicDevice(),
               device.inputChannelCount > 1 {
                channelModePicker(for: device)
            }

            if let device = manager.currentSelectedMicDevice() {
                inputControls(for: device)
            }

            VStack(spacing: 2) {
                Image(systemName: "mic")
                    .font(.system(size: 9))
                    .frame(height: 10)
                    .foregroundStyle(manager.micEnabled ? .primary : .secondary)
                Toggle(isOn: Binding(
                    get: { manager.micEnabled },
                    set: { enabled in Task { await manager.setMicEnabled(enabled) } }
                )) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Microphone capture")
            }
            .help("Microphone capture")

            VStack(spacing: 2) {
                let split = manager.channelSplit
                let micActive = manager.micStatus == .active
                let trueStereo = split && micActive
                HStack(spacing: split ? 2 : -3) {
                    Circle()
                        .fill(trueStereo ? Color.blue.opacity(0.25) : .clear)
                        .overlay(Circle().stroke(trueStereo ? .blue : .secondary, lineWidth: 1.2))
                        .frame(width: 8, height: 8)
                    Circle()
                        .fill(trueStereo ? Color.cyan.opacity(0.25) : split ? .secondary.opacity(0.4) : .clear)
                        .overlay(Circle().stroke(trueStereo ? .cyan : .secondary, lineWidth: 1.2))
                        .frame(width: 8, height: 8)
                }
                .frame(height: 10)
                Toggle(isOn: Binding(
                    get: { !manager.channelSplit },
                    set: { manager.updateChannelSplit(!$0) }
                )) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Mix microphone and system audio")
            }
            .help("Stereo: mixed together\nSplit: system in left, mic in right")

            VStack(spacing: 2) {
                let active = manager.liveTranscriptEnabled
                    && manager.liveTranscriptStream != nil
                Image(systemName: active ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: 9))
                    .frame(height: 10)
                    .foregroundStyle(active ? .purple : .secondary)
                Toggle(isOn: Binding(
                    get: { manager.liveTranscriptEnabled },
                    set: { enabled in
                        Task { await manager.setLiveTranscriptEnabled(enabled) }
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!manager.transcriptionService.modelsLoaded)
                .accessibilityLabel("Live Transcript")
            }
            .help("Live Transcript")
        }
    }

    @ViewBuilder
    private var micModeWarning: some View {
        if manager.micEnabled && manager.systemMicMode.isVoiceIsolation {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Mic Mode: Voice Isolation")
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Change") {
                    manager.openSystemMicModePicker()
                }
                .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(0.12))
            )
            .help("Voice Isolation can suppress USB instruments and other non-voice inputs. Use Standard or Wide Spectrum for raw audio.")
        }
    }

    // MARK: - Recent Recordings

    @ViewBuilder
    private var recentRecordingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Recordings")
                .font(.caption)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(manager.recentRecordings, id: \.url) { recording in
                        recordingRow(recording)
                    }
                }
            }
            .frame(height: recentsHeight)
        }
    }

    // MARK: - Resize Handle

    /// Thin bottom-edge band that resizes the recents section. Visually minimal
    /// at rest, brightens on hover. Uses .global coordinate space so the drag
    /// doesn't chase the moving view (local translation would underreport since
    /// the handle moves down with the growing popover).
    /// Visible grip line pinned to the popover's bottom edge. Not hit-testable —
    /// the drag gesture is attached to the whole bottom button row, so the
    /// entire row is draggable while the buttons still receive taps.
    @ViewBuilder
    private var resizeHandle: some View {
        Capsule()
            .fill(.secondary.opacity(resizeHovering ? 0.65 : 0.4))
            .frame(width: resizeHovering ? 48 : 36, height: 3)
            .padding(.bottom, 3)
            .allowsHitTesting(false)
    }

    /// Drag gesture shared between any draggable surface (currently the bottom
    /// button row). `minimumDistance: 5` lets button taps through — only real
    /// drags resize. Global coordinate space avoids a feedback loop where the
    /// moving view would otherwise chase the cursor.
    private var resizeDrag: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                if dragStartHeight == nil { dragStartHeight = recentsHeight }
                let base = dragStartHeight ?? recentsHeight
                recentsHeight = max(80, min(600, base + value.translation.height))
            }
            .onEnded { _ in dragStartHeight = nil }
    }

    @ViewBuilder
    private func recordingRow(_ recording: RecordingInfo) -> some View {
        RecordingRowView(
            recording: recording,
            manager: manager,
            renamingURL: $renamingURL,
            renameText: $renameText,
            transcribeTarget: $transcribeTarget,
            pendingTranscriptionConfig: $pendingTranscriptionConfig
        )
    }

    // MARK: - Global Hotkey

    private static var hotkeyInstalled = false

    private func setupGlobalHotkey() {
        guard !Self.hotkeyInstalled else { return }
        Self.hotkeyInstalled = true

        let mgr = manager

        let isHotkey: (NSEvent) -> Bool = { event in
            event.modifierFlags.contains([.command, .shift]) && event.keyCode == 15
        }

        let toggleRecording = {
            DispatchQueue.main.async {
                if mgr.state == .buffering { mgr.startRecording() }
                else if mgr.state == .recording { mgr.pauseRecording() }
                else if mgr.state == .paused { mgr.resumeRecording() }
            }
        }

        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if isHotkey(event) { toggleRecording() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if isHotkey(event) { toggleRecording(); return nil }
            return event
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct ConfigSummaryMenu<Items: View>: View {
    let title: String?
    let value: String
    let help: String
    let items: () -> Items

    @State private var isHovered = false

    private var label: String {
        title.map { "\($0): \(value)" } ?? value
    }

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                items()
            } label: {
                Text(label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.mini)
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(isHovered ? 0.18 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .fixedSize(horizontal: true, vertical: true)
        .help(help)
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            isHovered = phase != .ended
        }
    }
}

// MARK: - Recording Row

private struct RecordingRowView: View {
    let recording: RecordingInfo
    let manager: RecordingManager
    @Binding var renamingURL: URL?
    @Binding var renameText: String
    @Binding var transcribeTarget: RecordingInfo?
    @Binding var pendingTranscriptionConfig: TranscriptionConfig

    @State private var isHovered = false
    @State private var showSpeakerNaming = false
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        HStack {
            if renamingURL == recording.url {
                let stem = recording.url.deletingPathExtension().lastPathComponent
                let (base, _) = RecordingManager.parseFilenameParts(stem)
                HStack {
                    VStack(alignment: .leading) {
                        HStack(spacing: 0) {
                            Text(base + "_")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .fixedSize()
                            TextField("name", text: $renameText, onCommit: {
                                manager.renameRecording(recording, to: renameText)
                                renamingURL = nil
                            })
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
                            .focused($renameFieldFocused)
                            .onExitCommand { renamingURL = nil }
                        }
                        .lineLimit(1)
                        .onAppear { renameFieldFocused = true }
                        Text("\(recording.formattedDuration) - \(recording.formattedSize)")
                            .font(.caption2)
                    }
                    Spacer()
                }
            } else {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([recording.url])
                }) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(recording.filename)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(recording.formattedDuration) - \(recording.formattedSize)")
                                .font(.caption2)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens recording in Finder")
                .help("Show in Finder")
            }

            if renamingURL != recording.url {
                if manager.transcriptIsStale(for: recording) {
                    Text("stale")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Transcript is older than the audio file")
                }
                if let pending = manager.transcriptionService.unmatchedSpeakers[recording.url],
                   !pending.isEmpty {
                    let newCount = pending.filter { $0.name.isEmpty }.count
                    Button(action: { showSpeakerNaming = true }) {
                        Text(newCount > 0 ? "\(newCount) new" : "confirm")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.teal.opacity(0.2)))
                            .foregroundStyle(.teal)
                    }
                    .buttonStyle(.plain)
                    .help(newCount > 0 ? "Name new speakers" : "Confirm speaker identification")
                    .instantPopover(isPresented: $showSpeakerNaming, arrowEdge: .trailing) {
                        SpeakerNamingPopover(
                            fileURL: recording.url,
                            service: manager.transcriptionService
                        )
                    }
                }

                HStack(spacing: 6) {
                    Button(action: startRenaming) {
                        Image(systemName: "pencil")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename")

                    if manager.transcriptionService.transcribingURL == recording.url {
                        TranscriptionProgressIndicator(
                            phase: manager.transcriptionService.transcriptionPhase,
                            progress: manager.transcriptionService.transcriptionProgress
                        ) {
                            manager.transcriptionService.cancelTranscription()
                        }
                    } else if manager.transcriptionService.modelsLoaded {
                        Button(action: {
                            pendingTranscriptionConfig = manager.transcriptionConfig
                            transcribeTarget = recording
                        }) {
                            Image(systemName: transcriptExists() ? "arrow.triangle.2.circlepath" : "text.quote")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(manager.transcriptionService.isTranscribing)
                        .help(manager.transcriptIsStale(for: recording) ? "Transcript is stale — re-transcribe" : (transcriptExists() ? "Re-transcribe" : "Transcribe"))
                        .instantPopover(isPresented: Binding(
                            get: { transcribeTarget?.url == recording.url },
                            set: { if !$0 { transcribeTarget = nil } }
                        ), arrowEdge: .trailing) {
                            TranscriptionConfigPopover(config: $pendingTranscriptionConfig) {
                                let target = transcribeTarget
                                transcribeTarget = nil
                                if let target {
                                    manager.transcribeRecording(target, config: pendingTranscriptionConfig)
                                }
                            } onCancel: {
                                transcribeTarget = nil
                            }
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.primary.opacity(isHovered ? 0.06 : 0))
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Rename\u{2026}", action: startRenaming)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }
        }
    }

    private func startRenaming() {
        let stem = recording.url.deletingPathExtension().lastPathComponent
        let (_, name) = RecordingManager.parseFilenameParts(stem)
        renameText = name
        renamingURL = recording.url
    }

    private func transcriptExists() -> Bool {
        !manager.transcriptURLs(for: recording.url).isEmpty
    }
}

// MARK: - Transcription Progress

private struct TranscriptionProgressIndicator: View {
    let phase: TranscriptionPhase?
    let progress: Double?
    var onCancel: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onCancel) {
            ZStack {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .opacity(isHovered ? 0 : 1)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(isHovered ? 0 : 1)
                }
                Image(systemName: "stop.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("Cancel transcription")
        .accessibilityValue(accessibilityValue)
        .onHover { isHovered = $0 }
    }

    private var helpText: String {
        let stage: String
        switch phase {
        case .preparing: stage = "Preparing audio"
        case .transcribing: stage = "Transcribing"
        case .diarizing: stage = "Identifying speakers"
        case .finalizing: stage = "Finalizing transcript"
        case nil: stage = "Transcribing"
        }
        if let progress {
            return "\(stage) \(Int((progress * 100).rounded()))% - click to cancel"
        }
        return "\(stage) - click to cancel"
    }

    private var accessibilityValue: String {
        return helpText.replacingOccurrences(of: " - click to cancel", with: "")
    }
}

// MARK: - Speaker Naming Popover

private struct SpeakerNamingPopover: View {
    let fileURL: URL
    let service: TranscriptionService

    @State private var player: AVAudioPlayer?
    @State private var playingSpeaker: String?
    @State private var stopTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confirm Speakers")
                .font(.caption)

            if let speakers = service.unmatchedSpeakers[fileURL] {
                ForEach(speakers) { speaker in
                    HStack(spacing: 6) {
                        Button(action: { playSample(speakerID: speaker.id) }) {
                            Image(systemName: playingSpeaker == speaker.id ? "stop.fill" : "play.fill")
                                .font(.caption)
                                .foregroundStyle(.cyan)
                                .frame(width: 14)
                        }
                        .buttonStyle(.plain)
                        .help("Play sample")

                        Text(speaker.id)
                            .font(.caption)
                            .frame(width: 80, alignment: .leading)
                        SpeakerNameField(
                            name: Binding(
                                get: {
                                    service.unmatchedSpeakers[fileURL]?.first(where: { $0.id == speaker.id })?.name ?? ""
                                },
                                set: { newValue in
                                    guard let idx = service.unmatchedSpeakers[fileURL]?.firstIndex(where: { $0.id == speaker.id }) else { return }
                                    service.unmatchedSpeakers[fileURL]?[idx].name = newValue
                                }
                            ),
                            embedding: speaker.embedding,
                            profiles: service.speakerProfileStore?.profiles ?? []
                        )
                    }
                }
            }

            HStack {
                Button("Skip") {
                    stopPlayback()
                    service.skipNaming(for: fileURL)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    stopPlayback()
                    service.saveNewSpeakerProfiles(for: fileURL)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { stopPlayback() }
    }

    private func playSample(speakerID: String) {
        // If already playing this speaker, stop
        if playingSpeaker == speakerID {
            stopPlayback()
            return
        }

        stopPlayback()

        guard let range = service.randomSegmentRange(for: speakerID, fileURL: fileURL),
              let audioPlayer = try? AVAudioPlayer(contentsOf: fileURL) else { return }

        audioPlayer.currentTime = range.start
        audioPlayer.play()
        player = audioPlayer
        playingSpeaker = speakerID

        let duration = range.end - range.start
        stopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            Task { @MainActor in
                self.stopPlayback()
            }
        }
    }

    private func stopPlayback() {
        stopTimer?.invalidate()
        stopTimer = nil
        player?.stop()
        player = nil
        playingSpeaker = nil
    }
}

// MARK: - Speaker Name Autocomplete Field

/// Text field with similarity-ranked autocomplete suggestions from existing speaker profiles.
private struct SpeakerNameField: View {
    @Binding var name: String
    let embedding: [Float]
    let profiles: [SpeakerProfile]

    @State private var showSuggestions = false
    @State private var rankedNames: [String] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    showSuggestions = focused && !rankedNames.isEmpty
                }
                .onChange(of: name) { _, _ in
                    showSuggestions = isFocused && !filteredSuggestions.isEmpty
                }
                .onAppear {
                    rankedNames = profiles
                        .map { (name: $0.name, sim: SpeakerMatcher.cosineSimilarity(embedding, $0.embedding)) }
                        .sorted { $0.sim > $1.sim }
                        .map(\.name)
                }

            if showSuggestions && !filteredSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredSuggestions.prefix(5), id: \.self) { suggestion in
                        Button(action: {
                            name = suggestion
                            showSuggestions = false
                        }) {
                            Text(suggestion)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.separator, lineWidth: 0.5)
                )
                .cornerRadius(4)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            }
        }
    }

    private var filteredSuggestions: [String] {
        guard !name.isEmpty else { return rankedNames }
        return rankedNames.filter {
            $0.localizedCaseInsensitiveContains(name) && $0.caseInsensitiveCompare(name) != .orderedSame
        }
    }
}

// MARK: - Default-Mark Slider

/// A slider with a small tick mark indicating a reference default value.
struct DefaultMarkSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    var onEditingChanged: ((Bool) -> Void)?

    var body: some View {
        Slider(value: $value, in: range, step: step) {
            EmptyView()
        } onEditingChanged: { editing in
            onEditingChanged?(editing)
        }
        .overlay {
            GeometryReader { geo in
                let pad: CGFloat = 10
                let track = geo.size.width - pad * 2
                let frac = (defaultValue - range.lowerBound) / (range.upperBound - range.lowerBound)
                let x = pad + frac * track
                Rectangle()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 1.5, height: 8)
                    .position(x: x, y: geo.size.height - 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Speaker Count Picker

struct SpeakerCountPicker: View {
    @Binding var selection: Int
    private let quickPicks: [Int] = [-1, 2, 3]

    var body: some View {
        HStack(spacing: 4) {
            Text("Speakers")
                .font(.system(size: 11))
            Spacer()
            ForEach(quickPicks, id: \.self) { value in
                quickButton(value: value, label: value == -1 ? "A" : "\(value)")
            }
            moreMenu
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func quickButton(value: Int, label: String) -> some View {
        let button = Button {
            selection = value
        } label: {
            Text(label)
                .font(.system(size: 11))
                .frame(minWidth: 16)
        }
        if selection == value {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var moreMenu: some View {
        Menu {
            ForEach(4...10, id: \.self) { n in
                Button("\(n) speakers") {
                    selection = n
                }
            }
        } label: {
            Text(selection >= 4 ? "\(selection)" : "+")
                .font(.system(size: 11))
                .frame(minWidth: 16)
                .foregroundStyle(selection >= 4 ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selection >= 4 ? Color.accentColor : Color(nsColor: .controlColor))
        )
    }
}

// MARK: - Transcription Config Form & Popover

struct TranscriptionConfigForm: View {
    @Binding var config: TranscriptionConfig
    @State private var advancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Model", selection: $config.asrModelVersion) {
                Text("Multilingual (v3)").tag(ModelVersion.v3)
                Text("English (v2)").tag(ModelVersion.v2)
            }
            .controlSize(.small)

            Picker("Format", selection: $config.transcriptFormat) {
                ForEach(OutputFormat.allCases, id: \.self) { format in
                    Text(format.rawValue.uppercased()).tag(format)
                }
            }
            .controlSize(.small)

            Toggle("Remove filler words", isOn: $config.removeFillerWords)
                .controlSize(.small)

            Toggle("Speaker attribution", isOn: $config.diarizationEnabled)
                .controlSize(.small)

            if config.diarizationEnabled {
                Picker("Diarizer", selection: $config.diarizationEngine) {
                    Text("Pyannote").tag(DiarizationEngine.offline)
                    Text("LS-EEND").tag(DiarizationEngine.lseend)
                    Text("Sortformer").tag(DiarizationEngine.sortformer)
                }
                .controlSize(.small)

                Picker("Quality", selection: $config.diarizationQuality) {
                    Text("Fast").tag(DiarizationQuality.fast)
                    Text("Balanced").tag(DiarizationQuality.balanced)
                }
                .controlSize(.small)

                Picker("Sensitivity", selection: $config.speakerSensitivity) {
                    Text("Low").tag(SpeakerSensitivity.low)
                    Text("Medium").tag(SpeakerSensitivity.medium)
                    Text("High").tag(SpeakerSensitivity.high)
                }
                .controlSize(.small)

                SpeakerCountPicker(selection: $config.expectedSpeakerCount)

                expandableHeader("Advanced", isExpanded: $advancedExpanded)
                    .controlSize(.small)
                if advancedExpanded {
                    HStack {
                        Text("Speech threshold")
                        DefaultMarkSlider(value: $config.speechThreshold, range: 0.1...0.9, step: 0.05, defaultValue: 0.5)
                        Text(String(format: "%.2f", config.speechThreshold))
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 34)
                    }

                    HStack {
                        Text("Min segment")
                        DefaultMarkSlider(value: $config.minSegmentDuration, range: 0.05...2.0, step: 0.05, defaultValue: 1.0)
                        Text(String(format: "%.2fs", config.minSegmentDuration))
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 40)
                    }

                    HStack {
                        Text("Min gap")
                        DefaultMarkSlider(value: $config.minGapDuration, range: 0.0...1.0, step: 0.05, defaultValue: 0.1)
                        Text(String(format: "%.2fs", config.minGapDuration))
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
            }
        }
        .transaction { $0.animation = nil }
    }

    private func expandableHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(isExpanded.wrappedValue ? .degrees(90) : .zero)
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MicInputControls: View {
    @Bindable var manager: RecordingManager
    let device: AudioInputDevice

    @State private var showLatency = false
    @State private var showGain = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                showLatency.toggle()
            } label: {
                controlChip(
                    text: latencyLabel,
                    active: latencyActive,
                    tint: .blue
                )
            }
            .buttonStyle(.plain)
            .instantPopover(isPresented: $showLatency, arrowEdge: .bottom) {
                LatencyControlPanel(manager: manager, device: device)
                    .padding(10)
                    .frame(width: 260)
            }
            .help("Latency compensation")

            Button {
                showGain.toggle()
            } label: {
                controlChip(
                    text: "\(Self.formatSigned(manager.currentMicGainDB())) dB",
                    active: abs(manager.currentMicGainDB()) > 0.05,
                    tint: .green
                )
            }
            .buttonStyle(.plain)
            .instantPopover(isPresented: $showGain, arrowEdge: .bottom) {
                GainControlPanel(manager: manager, device: device)
                    .padding(10)
                    .frame(width: 240)
            }
            .help("Input gain")
        }
        .opacity(manager.micEnabled ? 1 : 0.4)
    }

    private var latencyActive: Bool {
        let settings = manager.currentMicLatencySettings()
        return settings.autoEnabled || abs(manager.currentEffectiveMicLatencyOffsetMs()) > 0.5
    }

    private var latencyLabel: String {
        let settings = manager.currentMicLatencySettings()
        let value = manager.currentEffectiveMicLatencyOffsetMs()
        if settings.autoEnabled {
            return "Auto \(Self.formatSigned(value))"
        }
        if abs(value) <= 0.5 {
            return "Lat Off"
        }
        return "Lat \(Self.formatSigned(value))"
    }

    private func controlChip(text: String, active: Bool, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? tint.opacity(0.18) : Color.secondary.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(active ? tint.opacity(0.65) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 4))
    }

    static func formatSigned(_ value: Double) -> String {
        let rounded = abs(value.rounded() - value) < 0.05 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        if value > 0 { return "+\(rounded)" }
        return rounded
    }
}

private struct LatencyControlPanel: View {
    @Bindable var manager: RecordingManager
    let device: AudioInputDevice

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Auto compensation", isOn: Binding(
                get: { manager.currentMicLatencySettings().autoEnabled },
                set: { manager.updateMicLatencyAutoEnabled($0, forUID: device.uid) }
            ))

            HStack {
                Text(manager.currentMicLatencySettings().autoEnabled ? "Trim" : "Offset")
                Slider(value: valueBinding, in: -250...250, step: 1)
                TextField("0", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 58)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
                Text("ms")
                    .foregroundStyle(.secondary)
            }

            if let estimate = manager.currentMicLatencyEstimate() {
                Text("Estimate \(MicInputControls.formatSigned(estimate.totalMs)) ms\(estimate.isPartial ? " partial" : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No CoreAudio latency estimate available")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Effective \(MicInputControls.formatSigned(manager.currentEffectiveMicLatencyOffsetMs())) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { reset() }
                    .controlSize(.small)
            }
        }
        .onAppear { syncText() }
        .onChange(of: manager.currentMicLatencySettings()) { _, _ in syncTextIfNeeded() }
        .onChange(of: device.uid) { _, _ in syncText() }
    }

    private var valueBinding: Binding<Double> {
        Binding(
            get: {
                let settings = manager.currentMicLatencySettings()
                return settings.autoEnabled ? settings.manualTrimMs : settings.manualOffsetMs
            },
            set: { value in
                let settings = manager.currentMicLatencySettings()
                if settings.autoEnabled {
                    manager.updateMicLatencyManualTrimMs(value, forUID: device.uid)
                } else {
                    manager.updateMicLatencyManualOffsetMs(value, forUID: device.uid)
                }
                text = Self.format(value)
            }
        )
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-", trimmed != "+", trimmed != "." else {
            syncText()
            return
        }
        guard let value = Double(trimmed) else {
            syncText()
            return
        }
        valueBinding.wrappedValue = MicLatencyStore.clamp(value)
        syncText()
    }

    private func reset() {
        if manager.currentMicLatencySettings().autoEnabled {
            manager.updateMicLatencyManualTrimMs(0, forUID: device.uid)
        } else {
            manager.updateMicLatencyManualOffsetMs(0, forUID: device.uid)
        }
        syncText()
    }

    private func syncTextIfNeeded() {
        if !focused { syncText() }
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private func syncText() {
        text = Self.format(valueBinding.wrappedValue)
    }
}

private extension View {
    func instantPopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) -> some View {
        overlay {
            InstantPopoverPresenter(
                isPresented: isPresented,
                arrowEdge: arrowEdge,
                content: { AnyView(content()) }
            )
            .allowsHitTesting(false)
        }
    }
}

private struct InstantPopoverPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let content: () -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPresented = $isPresented

        if isPresented {
            let popover = context.coordinator.popover ?? context.coordinator.makePopover()
            let controller = context.coordinator.hostingController ?? context.coordinator.makeHostingController()
            controller.rootView = content()
            popover.contentViewController = controller

            guard !popover.isShown else { return }
            if nsView.window != nil {
                show(popover, anchoredTo: nsView)
            } else {
                DispatchQueue.main.async {
                    guard isPresented, nsView.window != nil, !popover.isShown else { return }
                    show(popover, anchoredTo: nsView)
                }
            }
        } else if context.coordinator.popover?.isShown == true {
            context.coordinator.closeFromBinding()
        }
    }

    private func show(_ popover: NSPopover, anchoredTo nsView: NSView) {
        popover.show(
            relativeTo: nsView.bounds,
            of: nsView,
            preferredEdge: arrowEdge.nsRectEdge
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var isPresented: Binding<Bool>
        var popover: NSPopover?
        var hostingController: NSHostingController<AnyView>?
        private var closingFromBinding = false

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.animates = false
            popover.behavior = .transient
            popover.delegate = self
            self.popover = popover
            return popover
        }

        func makeHostingController() -> NSHostingController<AnyView> {
            let controller = NSHostingController(rootView: AnyView(EmptyView()))
            hostingController = controller
            return controller
        }

        func closeFromBinding() {
            closingFromBinding = true
            popover?.close()
            closingFromBinding = false
        }

        func popoverDidClose(_ notification: Notification) {
            guard !closingFromBinding else { return }
            DispatchQueue.main.async {
                self.isPresented.wrappedValue = false
            }
        }
    }
}

private extension Edge {
    var nsRectEdge: NSRectEdge {
        switch self {
        case .top:
            .minY
        case .bottom:
            .maxY
        case .leading:
            .maxX
        case .trailing:
            .minX
        }
    }
}

private struct GainControlPanel: View {
    @Bindable var manager: RecordingManager
    let device: AudioInputDevice

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gain")
                Slider(value: Binding(
                    get: { manager.currentMicGainDB() },
                    set: {
                        manager.updateMicGainDB($0, forUID: device.uid)
                        text = Self.format($0)
                    }
                ), in: -60...80, step: 1)
                TextField("0", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 58)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
                Text("dB")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(abs(manager.currentMicGainDB()) > 0.05 ? "Non-unity input gain" : "Unity gain")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    manager.updateMicGainDB(0, forUID: device.uid)
                    syncText()
                }
                .controlSize(.small)
            }
        }
        .onAppear { syncText() }
        .onChange(of: device.uid) { _, _ in syncText() }
        .onChange(of: manager.currentMicGainDB()) { _, _ in
            if !focused { syncText() }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-", trimmed != "+", trimmed != "." else {
            syncText()
            return
        }
        guard let value = Double(trimmed) else {
            syncText()
            return
        }
        manager.updateMicGainDB(value, forUID: device.uid)
        syncText()
    }

    private func syncText() {
        text = Self.format(manager.currentMicGainDB())
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

struct TranscriptionConfigPopover: View {
    @Binding var config: TranscriptionConfig
    var onTranscribe: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcription Settings")
                .font(.caption)

            TranscriptionConfigForm(config: $config)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Transcribe", action: onTranscribe)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .frame(width: 220)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
