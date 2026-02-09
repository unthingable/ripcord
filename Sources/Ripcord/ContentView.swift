import SwiftUI
import TranscribeKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var manager: RecordingManager

    @State private var transcribeTarget: RecordingInfo?
    @State private var pendingTranscriptionConfig = TranscriptionConfig()
    @State private var showFileTranscribePopover = false
    @State private var fileTranscribeURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status
            statusSection

            // Capture duration scrubber with level meters (buffering + recording)
            if manager.state == .buffering || manager.state == .recording {
                captureSlider
                    .onAppear { manager.startWaveformTimer() }
                    .onDisappear { manager.stopWaveformTimer() }
            }

            Divider()

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
                if manager.transcriptionService.modelsReady {
                    Button("Transcribe File\u{2026}") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.wav, .audio]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            fileTranscribeURL = url
                            pendingTranscriptionConfig = manager.transcriptionConfig
                            showFileTranscribePopover = true
                        }
                    }
                    .font(.caption)
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
                } else if case .loadingModels = manager.transcriptionService.state {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Loading models…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if case .downloadingModels = manager.transcriptionService.state {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Downloading models…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Quit") {
                    if manager.state == .recording {
                        manager.stopRecording()
                    }
                    manager.shutdown()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(8)
        .frame(width: 260)
        .onAppear {
            setupGlobalHotkey()
            // Launch in unstructured Task so it survives MenuBarExtra
            // view recreation during macOS permission dialogs.
            Task { await manager.startBufferingOnce() }
        }
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
            Button(action: {
                SettingsPanel.open(manager: manager)
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
        case .error: return .orange
        }
    }

    private var statusText: String {
        switch manager.state {
        case .starting:
            return "Starting..."
        case .buffering:
            let fill = manager.bufferFillSeconds
            let cap = manager.bufferDurationSeconds
            if fill >= cap {
                return "Buffering (Full - \(formatTime(cap)))"
            } else {
                return "Buffering (\(formatTime(fill)) / \(formatTime(cap)))"
            }
        case .recording:
            let elapsed = formatTime(Int(manager.recordingElapsed))
            if manager.isSilencePaused {
                return "Recording (\(elapsed)) - Silence"
            }
            return "Recording (\(elapsed))"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    // MARK: - Capture Waveform Scrubber

    @ViewBuilder
    private var captureSlider: some View {
        let isRecording = manager.state == .recording

        VStack(spacing: 4) {
            HStack {
                if isRecording {
                    Text("Recording")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Capture: \(formatTime(manager.captureDurationSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("/ \(formatTime(manager.bufferDurationSeconds))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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

                            let color: Color
                            if isRecording {
                                color = .red
                            } else {
                                let isCaptured = x >= handleX
                                color = isCaptured ? .accentColor : .primary.opacity(0.15)
                            }

                            let rect = CGRect(
                                x: x,
                                y: midY - barHeight / 2,
                                width: barWidth,
                                height: barHeight
                            )
                            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                        }

                        // Handle line (hidden during recording)
                        if !isRecording, handleX <= size.width {
                            let handleRect = CGRect(x: handleX - 1, y: 0, width: 2, height: size.height)
                            context.fill(
                                Path(roundedRect: handleRect, cornerRadius: 1),
                                with: .color(.primary.opacity(0.5))
                            )
                        }
                    }
                    .allowsHitTesting(!isRecording)
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
            verticalMeter(level: micLevel, color: .green)
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

    // MARK: - Record Button

    @ViewBuilder
    private var recordButton: some View {
        if manager.state == .recording {
            Button(action: { manager.stopRecording() }) {
                Label("Stop Recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: [.command])
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
        Text("Buffer: \(bufferLabel) min  \u{2022}  \(formatLabel)")
            .font(.caption)
            .foregroundStyle(.secondary)
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
            .disabled(!manager.micEnabled)
            .opacity(manager.micEnabled ? 1 : 0.4)

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
    }

    // MARK: - Recent Recordings

    @ViewBuilder
    private var recentRecordingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Recordings")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        VStack(alignment: .leading, spacing: 2) {
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
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens recording in Finder")

            // Per-recording transcription actions
            HStack(spacing: 8) {
                if manager.transcriptionService.transcribingURL == recording.url {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Transcribing\u{2026}")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if transcriptExists(for: recording) {
                    Button(action: { copyTranscript(for: recording) }) {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)

                    if manager.transcriptionService.modelsReady {
                        Button(action: {
                            pendingTranscriptionConfig = manager.transcriptionConfig
                            transcribeTarget = recording
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("Re-transcribe")
                    }
                } else if manager.transcriptionService.modelsReady {
                    Button(action: {
                        pendingTranscriptionConfig = manager.transcriptionConfig
                        transcribeTarget = recording
                    }) {
                        Label("Transcribe", systemImage: "waveform")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
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

    private func transcriptURL(for recording: RecordingInfo) -> URL? {
        let fm = FileManager.default
        let dir = recording.url.deletingLastPathComponent()
        let stem = recording.url.deletingPathExtension().lastPathComponent
        var newest: (url: URL, date: Date)?
        for format in OutputFormat.allCases {
            let ext = format.rawValue
            // Check base file, then -1, -2, ... until gap
            var i = 0
            while true {
                let name = i == 0 ? "\(stem).\(ext)" : "\(stem)-\(i).\(ext)"
                let url = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: url.path) else { break }
                if let mod = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
                   newest == nil || mod > newest!.date { newest = (url, mod) }
                i += 1
            }
        }
        return newest?.url
    }

    private func transcriptExists(for recording: RecordingInfo) -> Bool {
        let base = recording.url.deletingPathExtension()
        for format in OutputFormat.allCases {
            if FileManager.default.fileExists(atPath: base.appendingPathExtension(format.rawValue).path) { return true }
        }
        return false
    }

    private func copyTranscript(for recording: RecordingInfo) {
        guard let url = transcriptURL(for: recording),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
                else if mgr.state == .recording { mgr.stopRecording() }
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
                Picker("Sensitivity", selection: $config.speakerSensitivity) {
                    Text("Low").tag(SpeakerSensitivity.low)
                    Text("Medium").tag(SpeakerSensitivity.medium)
                    Text("High").tag(SpeakerSensitivity.high)
                }
                .controlSize(.small)

                Picker("Speakers", selection: $config.expectedSpeakerCount) {
                    Text("Auto").tag(-1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("4").tag(4)
                    Text("5+").tag(5)
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
                .foregroundStyle(.secondary)

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
    }
}
