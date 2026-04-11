import SwiftUI

/// Displays live transcript words grouped by speaker turns and phrases.
struct TranscriptPanel: View {
    @Bindable var state: TranscriptState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(state.turns) { turn in
                    TurnView(
                        turn: turn,
                        confirmedEnd: state.confirmedEnd(for: turn.source)
                    )
                }
            }
            .padding()
            .background {
                StickyBottom(enabled: !state.userScrolledUp)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                state.userScrolledUp.toggle()
            } label: {
                Image(systemName: state.userScrolledUp ? "arrow.down.to.line" : "pin.fill")
                    .font(.caption)
                    .frame(width: 24, height: 24)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .help(state.userScrolledUp ? "Resume autoscroll" : "Autoscroll on")
        }
    }
}

// MARK: - Sticky bottom via NSScrollView

/// When enabled, keeps the scroll view pinned to the bottom by observing
/// the document view's frame changes and scrolling directly via NSScrollView.
private struct StickyBottom: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let wasEnabled = context.coordinator.enabled
        context.coordinator.enabled = enabled
        // If just toggled on, scroll to bottom immediately
        if enabled && !wasEnabled {
            context.coordinator.scrollToBottom()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(enabled: enabled) }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        var enabled: Bool
        private weak var scrollView: NSScrollView?

        init(enabled: Bool) {
            self.enabled = enabled
        }

        func attach(to view: NSView) {
            guard let scrollView = view.enclosingScrollView else { return }
            self.scrollView = scrollView

            if let documentView = scrollView.documentView {
                documentView.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(documentFrameChanged),
                    name: NSView.frameDidChangeNotification,
                    object: documentView
                )
            }

            if enabled { scrollToBottom() }
        }

        @objc private func documentFrameChanged(_ note: Notification) {
            guard enabled else { return }
            scrollToBottom()
        }

        func scrollToBottom() {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let maxY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

// MARK: - Turn rendering

private struct TurnView: View {
    let turn: TranscriptTurn
    let confirmedEnd: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(turn.speakerLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(turn.source == "mic" ? .cyan : .blue)
                if let t = turn.startTime {
                    Text(formatTimestamp(t))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            styledText
                .font(.body)
                .textSelection(.enabled)
                .lineSpacing(2)
        }
    }

    private var styledText: Text {
        let phrases = turn.phrases
        guard !phrases.isEmpty else { return Text("") }
        var result = Text("")
        for (pi, phrase) in phrases.enumerated() {
            if pi > 0 { result = result + Text("  ") }
            for (wi, word) in phrase.words.enumerated() {
                if wi > 0 { result = result + Text(" ") }
                if word.isHypothesis {
                    result = result + Text(word.word)
                        .foregroundColor(.secondary.opacity(0.6))
                        .italic()
                } else {
                    let isConfirmed = word.end <= confirmedEnd
                    result = result + Text(word.word)
                        .foregroundColor(isConfirmed ? nil : .secondary)
                }
            }
        }
        return result
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
