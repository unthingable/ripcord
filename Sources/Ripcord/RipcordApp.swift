import SwiftUI

@main
struct RipcordApp: App {
    @State private var manager = RecordingManager()

    var body: some Scene {
        MenuBarExtra {
            ContentView(manager: manager)
        } label: {
            Label("Ripcord", systemImage: menubarIconName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(manager: manager)
        }
    }

    private var menubarIconName: String {
        switch manager.state {
        case .recording: return "waveform.circle.fill"
        case .error: return "exclamationmark.triangle"
        default: return "waveform.circle"
        }
    }
}
