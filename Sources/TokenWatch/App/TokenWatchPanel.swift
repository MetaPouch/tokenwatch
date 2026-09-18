import AppKit
import SwiftUI

/// Non-activating, key-capable panel hosting the dashboard popover. A regular `NSPopover`'s
/// window only reliably becomes key while the whole accessory app is active, which recent macOS
/// does not guarantee for `LSUIElement` apps -- this panel takes focus immediately on click.
final class TokenWatchPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = false
        hasShadow = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Anchors the panel's top-left under the status item button and shows it.
    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let origin = NSPoint(x: buttonFrame.midX - frame.width / 2, y: buttonFrame.minY - frame.height)
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
