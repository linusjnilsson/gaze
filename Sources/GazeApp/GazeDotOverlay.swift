import AppKit
import GazeKit
import SwiftUI

/// Click-through windows that draw the live gaze estimate on every display.
@MainActor
final class GazeDotOverlay {
    private var windows: [OverlayWindow] = []

    func show(engine: GazeEngine, showRaw: Bool) {
        hide()
        for screen in NSScreen.screens {
            let window = OverlayWindow.make(
                covering: screen.frame,
                interactive: false,
                content: GazeDotView(screenFrame: screen.frame, engine: engine, showRaw: showRaw)
            )
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func hide() {
        windows.forEach { $0.close() }
        windows = []
    }
}

private struct GazeDotView: View {
    let screenFrame: CGRect
    let engine: GazeEngine
    let showRaw: Bool

    var body: some View {
        ZStack {
            if showRaw, let raw = engine.rawGaze, screenFrame.contains(raw) {
                Circle()
                    .fill(.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .position(local(raw))
            }
            if let gaze = engine.gaze, screenFrame.contains(gaze) {
                Circle()
                    .strokeBorder(.orange, lineWidth: 3)
                    .background(Circle().fill(.orange.opacity(0.2)))
                    .frame(width: 44, height: 44)
                    .position(local(gaze))
                    // Glide between fixations instead of teleporting.
                    .animation(.spring(response: 0.22, dampingFraction: 0.9), value: gaze)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    /// Global AppKit coordinates (lower-left origin) → this window's SwiftUI coordinates (top-left origin).
    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - screenFrame.minX, y: screenFrame.maxY - p.y)
    }
}
