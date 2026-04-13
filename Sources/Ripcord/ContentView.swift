import AVFoundation
import SwiftUI
import TranscribeKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var manager: RecordingManager

    @State private var transcribeTarget: RecordingInfo?
    @State private var pendingTranscriptionConfig = TranscriptionConfig()
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showFileTranscribePopover = false
    @State private var fileTranscribeURL: URL?
    @State private var renamingURL: URL?
    @State private var renameText: String = ""
    // Stored outside @State to avoid MainActor-isolation issues in NotificationCenter closures
    private static nonisolated(unsafe) var settingsCloseObserver: NSObjectProtocol?

    var body: some View {
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
                    .popover(isPresented: $showFileTranscribePopover, arrowEdge: .top) {
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

            if let error = manager.transcriptionService.lastTranscriptionError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            setupGlobalHotkey()
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
                    $0 != panel && $0.canBecomeKey && $0.isVisible
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
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.headline)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(statusText)")
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
                    let captureFraction = Double(manager.captureDurationSeconds) / bufMax
                    let handleX = width * (1 - captureFraction)
                    let amps = manager.waveformAmplitudes
                    let states = manager.waveformBarStates

                    Canvas { context, size in
                        let barWidth: CGFloat = 2
                        let gap: CGFloat = 1
                        let step = barWidth + gap
                        let midY = size.height / 2

                        let totalBars = max(1, Int(size.width / step))
                        let filledBars = min(totalBars, manager.filledBarCount)
                        let startBar = totalBars - filledBars

                        for i in 0..<filledBars {
                            let x = CGFloat(startBar + i) * step
                            let amp = CGFloat(amps[100 - filledBars + i])
                            let barHeight = max(2, amp * size.height * 0.9)
                            let barState = states[100 - filledBars + i]

                            let color: Color
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

                            let rect = CGRect(
                                x: x,
                                y: midY - barHeight / 2,
                                width: barWidth,
                                height: barHeight
                            )
                            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                        }

                        // Handle line (hidden during recording/paused)
                        if !isCapturing, handleX <= size.width {
                            let handleRect = CGRect(x: handleX - 1, y: 0, width: 2, height: size.height)
                            context.fill(
                                Path(roundedRect: handleRect, cornerRadius: 1),
                                with: .color(.primary.opacity(0.5))
                            )
                        }
                    }
                    .allowsHitTesting(!isCapturing)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let fraction = 1 - (value.location.x / width)
                                let clamped = max(0, min(1, fraction))
                                let seconds = Int(clamped * bufMax)
                                manager.updateCaptureDuration(seconds)
                            }
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
            Button(action: { manager.startRecording() }) {
                Label("Record", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: [])
            .accessibilityHint("Starts recording, including buffered audio")
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
        let bufferLabel = manager.bufferDurationSeconds / 60
        let formatLabel = manager.outputFormat.rawValue
        let qualityLabel = manager.outputFormat == .wav
            ? "16-bit"
            : manager.audioQuality.label(for: manager.outputFormat)
        Text("Buffer: \(bufferLabel) min  \u{2022}  \(formatLabel)  \u{2022}  \(qualityLabel)")
            .font(.caption)
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
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(manager.micEnabled ? 1 : 0.4)

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
                .animation(.easeInOut(duration: 0.2), value: split)
                Toggle(isOn: Binding(
                    get: { !manager.channelSplit },
                    set: { manager.updateChannelSplit(!$0) }
                )) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
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
            }
            .help("Live Transcript")
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
            .frame(maxHeight: 160)
        }
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
                if let unmatched = manager.transcriptionService.unmatchedSpeakers[recording.url],
                   !unmatched.isEmpty {
                    Button(action: { showSpeakerNaming = true }) {
                        Text("\(unmatched.count) new")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.teal.opacity(0.2)))
                            .foregroundStyle(.teal)
                    }
                    .buttonStyle(.plain)
                    .help("Name new speakers")
                    .popover(isPresented: $showSpeakerNaming, arrowEdge: .trailing) {
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
                        CancelableSpinner {
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
                        .help(transcriptExists() ? "Re-transcribe" : "Transcribe")
                        .popover(isPresented: Binding(
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
        let base = recording.url.deletingPathExtension()
        for format in OutputFormat.allCases {
            if FileManager.default.fileExists(atPath: base.appendingPathExtension(format.rawValue).path) {
                return true
            }
        }
        return false
    }
}

// MARK: - Cancelable Spinner

/// A progress spinner that becomes a cancel button on hover.
private struct CancelableSpinner: View {
    var onCancel: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onCancel) {
            ZStack {
                ProgressView()
                    .controlSize(.small)
                    .opacity(isHovered ? 0 : 1)
                Image(systemName: "stop.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .help("Cancel transcription")
        .onHover { isHovered = $0 }
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
            Text("Name New Speakers")
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

// MARK: - Transcription Config Form & Popover

struct TranscriptionConfigForm: View {
    @Binding var config: TranscriptionConfig

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

                Picker("Speakers", selection: $config.expectedSpeakerCount) {
                    Text("Auto").tag(-1)
                    ForEach(2...10, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .controlSize(.small)

                DisclosureGroup("Advanced") {
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
                .controlSize(.small)
            }
        }
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
