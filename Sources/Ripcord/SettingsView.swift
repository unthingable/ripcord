import SwiftUI
import ServiceManagement
import TranscribeKit

struct SettingsView: View {
    @Bindable var manager: RecordingManager

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var isRecording: Bool { manager.state == .recording }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Recording") {
                    Picker("Buffer Duration", selection: Binding(
                        get: { manager.bufferDurationSeconds },
                        set: { manager.updateBufferDuration($0) }
                    )) {
                        Text("1 min").tag(60)
                        Text("5 min").tag(300)
                        Text("10 min").tag(600)
                        Text("15 min").tag(900)
                    }
                    .disabled(isRecording)

                    Picker("Format", selection: Binding(
                        get: { manager.outputFormat },
                        set: { manager.updateOutputFormat($0) }
                    )) {
                        ForEach(AudioOutputFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isRecording)

                    if manager.outputFormat == .wav {
                        LabeledContent("Quality", value: "16 kHz, 16-bit stereo")
                    } else {
                        Picker("Quality", selection: Binding(
                            get: { manager.audioQuality },
                            set: { manager.updateAudioQuality($0) }
                        )) {
                            ForEach(AudioQuality.allCases) { quality in
                                Text(quality.label(for: manager.outputFormat)).tag(quality)
                            }
                        }
                        .disabled(isRecording)
                    }

                    Toggle(micStatusLabel, isOn: Binding(
                        get: { manager.micEnabled },
                        set: { enabled in
                            Task { await manager.setMicEnabled(enabled) }
                        }
                    ))
                }

                Section("Silence Detection") {
                    Toggle("Auto-pause", isOn: Binding(
                        get: { manager.silenceAutoPauseEnabled },
                        set: { manager.updateSilenceAutoPause(enabled: $0) }
                    ))

                    HStack {
                        Text("Threshold")
                        Slider(
                            value: Binding(
                                get: { manager.silenceThreshold },
                                set: { manager.updateSilenceThreshold($0) }
                            ),
                            in: 0.001...0.1
                        )
                        Text(String(format: "%.3f", manager.silenceThreshold))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                    .disabled(!manager.silenceAutoPauseEnabled)

                    Picker("Timeout", selection: Binding(
                        get: { manager.silenceTimeoutSeconds },
                        set: { manager.updateSilenceTimeout($0) }
                    )) {
                        Text("1s").tag(1.0)
                        Text("3s").tag(3.0)
                        Text("5s").tag(5.0)
                        Text("10s").tag(10.0)
                    }
                    .disabled(!manager.silenceAutoPauseEnabled)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Form {
                Section("Transcription") {
                    transcriptionSection
                }

                Section("General") {
                    LabeledContent("File Prefix") {
                        VStack(alignment: .trailing, spacing: 2) {
                            TextField("", text: Binding(
                                get: { manager.filePrefix },
                                set: { manager.updateFilePrefix($0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)

                            let preview = manager.filePrefix.trimmingCharacters(in: .whitespaces).isEmpty
                                ? "2024-01-01_12-00-00.wav"
                                : "\(manager.filePrefix.trimmingCharacters(in: .whitespaces))_2024-01-01_12-00-00.wav"
                            Text(preview)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    LabeledContent("Recordings") {
                        HStack {
                            Text(manager.outputDirectory.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Change\u{2026}") {
                                chooseOutputDirectory()
                            }
                        }
                    }

                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            setLaunchAtLogin(newValue)
                        }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 700)
    }

    @ViewBuilder
    private var transcriptionSection: some View {
        let tsState = manager.transcriptionService.state

        switch tsState {
        case .idle:
            Button("Download Models\u{2026}") {
                manager.downloadTranscriptionModels()
            }
            Text("Required for transcription")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .loadingModels:
            ProgressView()
                .controlSize(.small)
            Text("Loading models\u{2026}")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .downloadingModels(let progress):
            ProgressView(value: progress)
            Text("Downloading models\u{2026}")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .failed(let error):
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            Button("Retry") {
                manager.downloadTranscriptionModels()
            }
            .font(.caption)

        case .ready, .transcribing:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Models ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Transcribe recordings", isOn: Binding(
                get: { manager.transcriptionEnabled },
                set: { manager.updateTranscriptionEnabled($0) }
            ))

            Picker("Language Model", selection: manager.transcriptionConfigBinding(\.asrModelVersion)) {
                Text("Multilingual (v3)").tag(ModelVersion.v3)
                Text("English (v2)").tag(ModelVersion.v2)
            }
            .pickerStyle(.segmented)

            Picker("Transcript Format", selection: manager.transcriptionConfigBinding(\.transcriptFormat)) {
                ForEach(OutputFormat.allCases, id: \.self) { format in
                    Text(format.rawValue.uppercased()).tag(format)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Remove filler words", isOn: manager.transcriptionConfigBinding(\.removeFillerWords))

            Toggle("Speaker attribution", isOn: manager.transcriptionConfigBinding(\.diarizationEnabled))

            Picker("Quality", selection: manager.transcriptionConfigBinding(\.diarizationQuality)) {
                Text("Fast").tag(DiarizationQuality.fast)
                Text("Balanced").tag(DiarizationQuality.balanced)
            }
            .pickerStyle(.segmented)
            .disabled(!manager.transcriptionConfig.diarizationEnabled)

            Picker("Speaker sensitivity", selection: manager.transcriptionConfigBinding(\.speakerSensitivity)) {
                Text("Low").tag(SpeakerSensitivity.low)
                Text("Medium").tag(SpeakerSensitivity.medium)
                Text("High").tag(SpeakerSensitivity.high)
            }
            .disabled(!manager.transcriptionConfig.diarizationEnabled)

            Picker("Expected speakers", selection: manager.transcriptionConfigBinding(\.expectedSpeakerCount)) {
                Text("Auto").tag(-1)
                ForEach(2...10, id: \.self) { n in
                    Text("\(n)").tag(n)
                }
            }
            .disabled(!manager.transcriptionConfig.diarizationEnabled)

            DisclosureGroup("Advanced") {
                HStack {
                    Text("Speech threshold")
                    DefaultMarkSlider(
                        value: manager.transcriptionConfigBinding(\.speechThreshold),
                        range: 0.1...0.9, step: 0.05, defaultValue: 0.5
                    )
                    Text(String(format: "%.2f", manager.transcriptionConfig.speechThreshold))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 34)
                }

                HStack {
                    Text("Min segment")
                    DefaultMarkSlider(
                        value: manager.transcriptionConfigBinding(\.minSegmentDuration),
                        range: 0.05...2.0, step: 0.05, defaultValue: 1.0
                    )
                    Text(String(format: "%.2fs", manager.transcriptionConfig.minSegmentDuration))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Min gap")
                    DefaultMarkSlider(
                        value: manager.transcriptionConfigBinding(\.minGapDuration),
                        range: 0.0...1.0, step: 0.05, defaultValue: 0.1
                    )
                    Text(String(format: "%.2fs", manager.transcriptionConfig.minGapDuration))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }
            .disabled(!manager.transcriptionConfig.diarizationEnabled)
        }
    }

    private var micStatusLabel: String {
        switch manager.micStatus {
        case .permissionDenied:  "Microphone (no permission)"
        case .failed:            "Microphone (failed)"
        case .off, .active:      "Microphone"
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = manager.outputDirectory
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            manager.updateOutputDirectory(url)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
