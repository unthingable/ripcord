import SwiftUI

@main
struct RipcordApp: App {
    @State private var manager: RecordingManager

    init() {
        let mgr = RecordingManager()
        _manager = State(initialValue: mgr)
        // Apply saved appearance override after NSApp is available
        Task { @MainActor in
            let raw = UserDefaults.standard.string(forKey: SettingsKey.appearanceOverride) ?? "system"
            AppearanceMode.apply(AppearanceMode(rawValue: raw) ?? .system)
        }
        Task { await mgr.startBufferingOnce() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in mgr.shutdown() }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(manager: manager)
        } label: {
            Image(nsImage: menubarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(manager: manager)
        }

        Window("Live Transcript", id: "copilot") {
            CopilotView(manager: manager)
        }
        .defaultSize(width: 600, height: 500)
    }

    private var menubarIcon: NSImage {
        let name: String
        let tint: NSColor?
        switch manager.state {
        case .recording:
            name = "waveform.circle.fill"
            tint = .systemRed
        case .paused:
            name = "waveform.circle.fill"
            tint = .systemOrange
        case .error:
            name = "exclamationmark.triangle"
            tint = nil
        default:
            name = manager.liveTranscriptEnabled && manager.liveTranscriptStream != nil
                ? "waveform.circle.fill" : "waveform.circle"
            tint = manager.liveTranscriptEnabled && manager.liveTranscriptStream != nil
                ? .systemPurple : nil
        }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Ripcord")!
            .withSymbolConfiguration(config)!

        guard let tint else {
            image.isTemplate = true
            return image
        }

        // Render tinted so macOS shows actual color instead of template monochrome
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }
}
