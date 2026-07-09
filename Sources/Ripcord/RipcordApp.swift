import SwiftUI
import TranscribeKit

@main
struct RipcordApp: App {
    @State private var manager: RecordingManager
    @State private var updateChecker = UpdateChecker()

    init() {
        let mgr = RecordingManager()
        _manager = State(initialValue: mgr)
        ProcessInfo.processInfo.disableAutomaticTermination("Ripcord runs as a menu bar recorder")
        // Apply saved appearance override after NSApp is available
        Task { @MainActor in
            let raw = UserDefaults.standard.string(forKey: SettingsKey.appearanceOverride) ?? "system"
            AppearanceMode.apply(AppearanceMode(rawValue: raw) ?? .system)
        }
        let checker = _updateChecker.wrappedValue
        Task {
            await mgr.startBufferingOnce()
            // Prompt to download models on first launch
            await MainActor.run { Self.promptForModelDownloadIfNeeded(manager: mgr) }
            await checker.check()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in mgr.shutdown() }
    }

    @MainActor
    private static func promptForModelDownloadIfNeeded(manager: RecordingManager) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsKey.modelDownloadPromptDismissed) else { return }
        guard !TranscriptionService.modelsExistOnDisk(config: manager.transcriptionConfig) else { return }

        let alert = NSAlert()
        alert.messageText = "Download Transcription Models"
        alert.informativeText = "Ripcord needs to download speech recognition models to enable transcription. This is a one-time download of about 150 MB."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        defaults.set(true, forKey: SettingsKey.modelDownloadPromptDismissed)

        if response == .alertFirstButtonReturn {
            manager.downloadTranscriptionModels()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(manager: manager)
        } label: {
            Image(nsImage: menubarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(manager: manager, updateChecker: updateChecker)
        }

        Window("Live Transcript", id: "copilot") {
            CopilotView(manager: manager)
        }
        .defaultSize(width: 600, height: 500)
    }

    private var menubarIcon: NSImage {
        let innerTint: NSColor?
        switch manager.state {
        case .recording:
            innerTint = .systemRed
        case .paused:
            innerTint = .systemOrange
        case .error:
            return statusSymbol("exclamationmark.triangle", tint: .systemRed)
        default:
            innerTint = manager.liveTranscriptEnabled && manager.liveTranscriptStream != nil
                ? .systemPurple : nil
        }

        return inputColoredIcon(innerTint: innerTint)
    }

    private func statusSymbol(_ name: String, tint: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Ripcord")!
            .withSymbolConfiguration(config)!
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private func inputColoredIcon(innerTint: NSColor?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let inputColor = selectedInputColor
        let image = NSImage(size: size, flipped: false) { rect in
            let circleRect = rect.insetBy(dx: 1.6, dy: 1.6)
            let path = NSBezierPath(ovalIn: circleRect)
            inputColor.withAlphaComponent(0.22).setFill()
            path.fill()
            inputColor.setStroke()
            path.lineWidth = 1.6
            path.stroke()

            let symbolName = innerTint == nil ? "waveform" : "waveform"
            let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else {
                return true
            }
            let symbolRect = NSRect(x: rect.midX - 5.5, y: rect.midY - 5.5, width: 11, height: 11)
            let tint = innerTint ?? NSColor.labelColor
            symbol.draw(in: symbolRect)
            tint.set()
            symbolRect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    private var selectedInputColor: NSColor {
        guard manager.micEnabled else { return .systemGray }
        guard let device = manager.currentSelectedMicDevice() else { return .systemTeal }
        if device.uid == manager.selectedMicUID {
            return device.isUSBTransport ? .systemBlue : .systemGreen
        }
        return .systemTeal
    }
}
