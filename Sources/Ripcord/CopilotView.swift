import SwiftUI

/// Live transcript window. Phase 2: transcript only. Phase 3 will add chat + sidebar.
struct CopilotView: View {
    var manager: RecordingManager
    @State private var transcriptState = TranscriptState()
    @State private var chunkSize: Double = 2.0
    @State private var rightContext: Double = 0.5
    @State private var confirmation: Double = 0.65

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Live Transcript")
                    .font(.headline)
                Spacer()
                statusBadge
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Controls
            VStack(spacing: 4) {
                configSlider(
                    label: "Chunk",
                    value: $chunkSize, range: 1.0...8.0, step: 0.5,
                    format: "%.1fs"
                ) {
                    Task {
                        transcriptState.clear()
                        await manager.setLiveTranscriptChunkSize(chunkSize)
                        await reconnectToStream()
                    }
                }
                configSlider(
                    label: "Lookahead",
                    value: $rightContext, range: 0.0...2.0, step: 0.1,
                    format: "%.1fs"
                ) {
                    Task {
                        transcriptState.clear()
                        await manager.setLiveTranscriptRightContext(rightContext)
                        await reconnectToStream()
                    }
                }
                configSlider(
                    label: "Confirm",
                    value: $confirmation, range: 0.0...1.0, step: 0.05,
                    format: "%.2f"
                ) {
                    Task {
                        transcriptState.clear()
                        await manager.setLiveTranscriptConfirmation(confirmation)
                        await reconnectToStream()
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 6)

            Divider()

            // Transcript
            if transcriptState.turns.isEmpty {
                emptyState
            } else {
                TranscriptPanel(state: transcriptState)
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            chunkSize = manager.liveTranscriptChunkSize
            rightContext = manager.liveTranscriptRightContext
            confirmation = manager.liveTranscriptConfirmation
        }
        .task {
            await connectToStream()
        }
        .onDisappear {
            transcriptState.stopConsuming()
        }
    }

    private func configSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 60, alignment: .trailing)
            Slider(value: value, in: range, step: step) {
                EmptyView()
            } onEditingChanged: { editing in
                if !editing { onCommit() }
            }
            Text(String(format: format, value.wrappedValue))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 36, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let streaming = manager.liveTranscriptEnabled
            && manager.liveTranscriptStream != nil
        HStack(spacing: 4) {
            Circle()
                .fill(streaming ? .green : .gray)
                .frame(width: 6, height: 6)
            Text(streaming ? "Live" : "Offline")
                .font(.caption2)
                .foregroundStyle(streaming ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            if manager.liveTranscriptEnabled {
                Text("Waiting for speech…")
                    .foregroundStyle(.secondary)
            } else {
                Text("Live transcript is off")
                    .foregroundStyle(.secondary)
                Text("Enable it in Settings → Live Transcript")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func connectToStream() async {
        guard let stream = manager.liveTranscriptStream?.wordStream else { return }
        transcriptState.startConsuming(stream)
    }

    private func reconnectToStream() async {
        transcriptState.stopConsuming()
        try? await Task.sleep(for: .milliseconds(200))
        await connectToStream()
    }
}
