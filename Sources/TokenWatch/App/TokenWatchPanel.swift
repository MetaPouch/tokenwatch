import AppKit
import SwiftUI

/// Non-activating, key-capable panel hosting the dashboard popover. A regular `NSPopover`'s
/// window only reliably becomes key while the whole accessory app is active, which recent macOS
/// does not guarantee for `LSUIElement` apps -- this panel takes focus immediately on click.
///
/// Fixed width, dynamic height: the popover's content (the dashboard/customize/settings pager)
/// reports its natural height back through `onHeightChange`, and `setContentHeight` resizes the
/// window to match, anchoring the *top* edge (fixed just under the status item button) so only
/// the bottom edge moves -- matching how a real dropdown grows/shrinks in place instead of
/// staying a fixed size with an internal scrollbar for short content.
final class TokenWatchPanel: NSPanel {
    static let width: CGFloat = 320

    init<Content: View>(initialHeight: CGFloat, content: @escaping (@escaping (CGFloat) -> Void) -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: initialHeight),
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
        contentView = NSHostingView(rootView: content { [weak self] newHeight in
            self?.setContentHeight(newHeight)
        })
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Excludes this window from screen recordings/screen sharing when `hidden`, restores normal
    /// sharing otherwise.
    func setHiddenFromScreenShare(_ hidden: Bool) {
        sharingType = hidden ? .none : .readWrite
    }

    /// Anchors the panel's top-left under the status item button and shows it.
    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let origin = NSPoint(x: buttonFrame.midX - frame.width / 2, y: buttonFrame.minY - frame.height)
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Resizes to `height`, keeping the top edge fixed (just under the status item button) so a
    /// screen switch or content change grows/shrinks from the bottom, never repositions upward
    /// into the menu bar or jumps sideways.
    private func setContentHeight(_ height: CGFloat) {
        let clamped = max(height, 80)
        guard abs(clamped - frame.height) > 0.5 else { return }
        let topEdge = frame.origin.y + frame.height
        var newFrame = frame
        newFrame.size.height = clamped
        newFrame.origin.y = topEdge - clamped
        setFrame(newFrame, display: true, animate: isVisible)
    }
}
