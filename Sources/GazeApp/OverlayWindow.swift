import AppKit
import SwiftUI

/// A borderless, full-screen window floating above everything, including full-screen apps.
final class OverlayWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let onKeyDown {
            onKeyDown(event)
        } else {
            super.keyDown(with: event)
        }
    }

    static func make(covering frame: CGRect, interactive: Bool, content: some View) -> OverlayWindow {
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = !interactive
        window.isReleasedWhenClosed = false
        // Appear and disappear at once, without the system fade.
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: content)
        return window
    }
}
