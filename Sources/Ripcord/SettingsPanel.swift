import AppKit
import SwiftUI

@MainActor
final class SettingsPanel {
    static let shared = SettingsPanel()
    private var panel: NSPanel?

    func open(manager: RecordingManager) {
        if let panel, panel.isVisible {
            panel.orderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Ripcord Settings"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: SettingsView(manager: manager))
        panel.center()
        panel.orderFront(nil)
        self.panel = panel
    }
}
