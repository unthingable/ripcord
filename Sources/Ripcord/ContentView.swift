import SwiftUI
import TranscribeKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var manager: RecordingManager

    @State private var transcribeTarget: RecordingInfo?
    @State private var pendingTranscriptionConfig = TranscriptionConfig()
    @Environment(\.openSettings) private var openSettings
    @State private var showFileTranscribePopover = false
    @State private var fileTranscribeURL: URL?
    @State private var renamingURL: URL?
    @State private var renameText: String = ""

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

            // Recording name field
            if manager.state == .buffering || manager.state == .recording {
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
                    }
                } else if case .downloadingModels = manager.transcriptionService.state {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Downloading models…")
                            .font(.caption2)
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
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            setupGlobalHotkey()
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
                NSApp.activate()
                openSettings()
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
                        .foregroundStyle(.secondary)
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

    // MARK: - Name Field

    @ViewBuilder
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Name this recording\u{2026}", text: $manager.recordingName)
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white))
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

// MARK: - Recording Row

private struct RecordingRowView: View {
    let recording: RecordingInfo
    let manager: RecordingManager
    @Binding var renamingURL: URL?
    @Binding var renameText: String
    @Binding var transcribeTarget: RecordingInfo?
    @Binding var pendingTranscriptionConfig: TranscriptionConfig

    @State private var isHovered = false

    var body: some View {
        HStack {
            Button(action: {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }) {
                HStack {
                    VStack(alignment: .leading) {
                        if renamingURL == recording.url {
                            let stem = recording.url.deletingPathExtension().lastPathComponent
                            let (base, _) = RecordingManager.parseFilenameParts(stem)
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
                                .background(RoundedRectangle(cornerRadius: 4).fill(.white))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
                                .onExitCommand { renamingURL = nil }
                            }
                            .lineLimit(1)
                        } else {
                            Text(recording.filename)
                                .font(.caption)
                                .lineLimit(1)
                        }
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

            if renamingURL != recording.url {
                HStack(spacing: 6) {
                    Button(action: startRenaming) {
                        Image(systemName: "pencil")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename")

                    if manager.transcriptionService.transcribingURL == recording.url {
                        ProgressView().controlSize(.small)
                    } else if manager.transcriptionService.modelsReady {
                        Button(action: {
                            pendingTranscriptionConfig = manager.transcriptionConfig
                            transcribeTarget = recording
                        }) {
                            Image(systemName: transcriptExists() ? "arrow.triangle.2.circlepath" : "waveform")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
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

// MARK: - Default-Mark Slider

/// A slider with a small tick mark indicating a reference default value.
struct DefaultMarkSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double

    var body: some View {
        Slider(value: $value, in: range, step: step)
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
