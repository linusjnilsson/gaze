import AppKit
import GazeKit
import SwiftUI

/// Shows every window as a tile, a grid per display, while the trigger and ⇧ are held; the tile
/// the user looks at is highlighted, or the one under the pointer once the mouse moves. The
/// overlays take clicks while shown, so a click picks a tile instead of reaching the app below.
@MainActor
final class WindowOverviewPanel {
    struct Tile: Identifiable {
        var window: ScreenWindow
        /// Global AppKit coordinates.
        var frame: CGRect
        var icon: NSImage?
        var title: String?
        var id: UInt32 { window.id }
    }

    private(set) var tiles: [Tile] = []
    private(set) var selected: Int?
    private let state = OverviewState()
    private var windows: [OverlayWindow] = []

    var isShown: Bool { !windows.isEmpty }

    func show(windows screenWindows: [ScreenWindow], displays: [CGRect], title: (ScreenWindow) -> String?) {
        hide()
        let groups = WindowOverview.byDisplay(screenWindows, displays: displays)
        tiles = zip(displays, groups).flatMap { display, group in
            let group = WindowOverview.ordered(group)
            return zip(group, WindowOverview.layout(group, in: display)).map { window, frame in
                Tile(window: window, frame: frame, icon: NSRunningApplication(processIdentifier: window.pid)?.icon, title: title(window))
            }
        }
        state.tiles = tiles
        state.selected = nil
        selected = nil
        for display in displays {
            let overlay = OverlayWindow.make(covering: display, interactive: true, content: OverviewView(state: state, display: display))
            overlay.orderFrontRegardless()
            windows.append(overlay)
        }
    }

    /// The tile at `point` (global AppKit coordinates), or one just beside it.
    func tile(at point: CGPoint) -> Int? {
        WindowOverview.pick(gaze: point, sigma: Double(Self.pointerReach) / 3, tiles: tiles.map(\.frame), current: nil)
    }

    /// How far from a tile the pointer still picks it, in points: less than the gap between tiles.
    static let pointerReach: CGFloat = 12

    func select(_ index: Int?) {
        guard index != selected else { return }
        selected = index
        state.selected = index
    }

    func hide() {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = []
        tiles = []
        selected = nil
    }
}

@MainActor
@Observable
private final class OverviewState {
    var tiles: [WindowOverviewPanel.Tile] = []
    var selected: Int?
}

private struct OverviewView: View {
    let state: OverviewState
    /// The display this view covers, to place the tiles (global, lower-left origin) in it.
    let display: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.45)
            ForEach(Array(state.tiles.enumerated()), id: \.element.id) { index, tile in
                if display.intersects(tile.frame) {
                    TileView(tile: tile, isSelected: index == state.selected)
                        .frame(width: tile.frame.width, height: tile.frame.height)
                        .offset(x: tile.frame.minX - display.minX, y: display.maxY - tile.frame.maxY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

private struct TileView: View {
    let tile: WindowOverviewPanel.Tile
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        VStack(spacing: 8) {
            if let icon = tile.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
            }
            Text(tile.window.appName)
                .font(.headline)
            if let title = tile.title, title != tile.window.appName {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.25), lineWidth: isSelected ? 5 : 1))
        .shadow(color: .black.opacity(isSelected ? 0.5 : 0.25), radius: isSelected ? 16 : 6)
        .scaleEffect(isSelected ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var iconSize: CGFloat {
        min(max(min(tile.frame.width, tile.frame.height) / 3, 32), 96)
    }
}
