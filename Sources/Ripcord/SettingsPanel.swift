import AppKit
import SwiftUI

@MainActor
final class SettingsPanel {
    static let shared = SettingsPanel()
    private var panel: NSPanel?

    func open(manager: RecordingManager, anchorWindow: NSWindow? = nil) {
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

        // Position below the anchor window, right-aligned
        if let anchor = anchorWindow {
            // Layout so the panel knows its size
            panel.layoutIfNeeded()
            let anchorFrame = anchor.frame
            let panelSize = panel.frame.size
            let gap: CGFloat = 4

            // Align top-right of settings with bottom-right of anchor
            var origin = NSPoint(
                x: anchorFrame.maxX - panelSize.width,
                y: anchorFrame.minY - panelSize.height - gap
            )

            // Clamp to screen bounds
            if let screen = anchor.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                origin.x = max(visible.minX, min(origin.x, visible.maxX - panelSize.width))
                origin.y = max(visible.minY, min(origin.y, visible.maxY - panelSize.height))
            }

            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        panel.orderFront(nil)
        self.panel = panel
    }
}
