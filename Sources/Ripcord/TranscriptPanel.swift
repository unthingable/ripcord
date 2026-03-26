import SwiftUI

/// Displays live transcript words grouped by speaker turns and phrases.
struct TranscriptPanel: View {
    @Bindable var state: TranscriptState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(state.turns) { turn in
                        TurnView(turn: turn)
                    }

                    // Anchor for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding()
                .background(scrollDetector)
            }
            .onChange(of: state.turns.last?.phrases.last?.words.count) {
                guard !state.userScrolledUp else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    /// Detects manual scroll to disable auto-scroll.
    private var scrollDetector: some View {
        GeometryReader { geo in
            Color.clear
                .preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("scroll")).minY)
        }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TurnView: View {
    let turn: TranscriptTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(turn.speakerLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(turn.source == "mic" ? .blue : .secondary)
                if let t = turn.startTime {
                    Text(formatTimestamp(t))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(turn.fullText)
                .font(.body)
                .textSelection(.enabled)
                .lineSpacing(2)
        }
    }

    private func formatTimestamp(_ t: TimeInterval) -> String {
        let totalSeconds = Int(t)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
