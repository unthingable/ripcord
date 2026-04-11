import SwiftUI

/// Live transcript window. Phase 2: transcript only. Phase 3 will add chat + sidebar.
struct CopilotView: View {
    var manager: RecordingManager
    @State private var transcriptState = TranscriptState()
    @State private var chunkSize: Double = 3.0
    @State private var rightContext: Double = 1.0
    @State private var minContext: Double = 5.0
    @State private var confirmThreshold: Double = 0.65
    @State private var showControls = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Live Transcript")
                    .font(.headline)
                Spacer()
                Button {
                    transcriptState.userScrolledUp.toggle()
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(
                            transcriptState.userScrolledUp
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help(transcriptState.userScrolledUp ? "Click to resume autoscroll" : "Click to pin view and stop autoscroll")
                Button {
                    showControls.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(showControls ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle tuning controls")
                statusBadge
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Controls (collapsible)
            if showControls {
                VStack(spacing: 6) {
                    configRow("Chunk", value: $chunkSize, range: 1.0...8.0, step: 0.5,
                              defaultValue: 3.0, format: "%.1fs") {
                        Task { await manager.setLiveTranscriptChunkSize(chunkSize) }
                    }
                    configRow("Lookahead", value: $rightContext, range: 0.0...2.0, step: 0.1,
                              defaultValue: 1.0, format: "%.1fs") {
                        Task { await manager.setLiveTranscriptRightContext(rightContext) }
                    }
                    configRow("Min context", value: $minContext, range: 2.0...10.0, step: 0.5,
                              defaultValue: 5.0, format: "%.1fs") {
                        Task { await manager.setLiveTranscriptMinContext(minContext) }
                    }
                    configRow("Confirm", value: $confirmThreshold, range: 0.3...0.95, step: 0.05,
                              defaultValue: 0.65, format: "%.2f") {
                        Task { await manager.setLiveTranscriptConfirmThreshold(confirmThreshold) }
                    }
                }
                .controlSize(.small)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            Divider()

            // Transcript
            if transcriptState.turns.isEmpty {
                emptyState
            } else {
                TranscriptPanel(state: transcriptState)
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            chunkSize = manager.liveTranscriptChunkSize
            rightContext = manager.liveTranscriptRightContext
            minContext = manager.liveTranscriptMinContext
            confirmThreshold = manager.liveTranscriptConfirmThreshold
        }
        .task(id: manager.liveTranscriptStream.map { ObjectIdentifier($0) }) {
            await connectToStream()
        }
        .onDisappear {
            transcriptState.stopConsuming()
        }
    }

    private func configRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        defaultValue: Double,
        format: String,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(width: 72, alignment: .trailing)
            DefaultMarkSlider(
                value: value, range: range, step: step, defaultValue: defaultValue,
                onEditingChanged: { editing in if !editing { onCommit() } }
            )
            Text(String(format: format, value.wrappedValue))
                .font(.caption)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(width: 40, alignment: .leading)
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
}
