import AppKit
import SwiftUI

@MainActor
enum SettingsPanel {
    private static var panel: NSPanel?

    static func open(manager: RecordingManager) {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Ripcord Settings"
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: SettingsView(manager: manager))

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}
