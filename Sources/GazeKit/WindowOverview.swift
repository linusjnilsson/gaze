import CoreGraphics
import Foundation

/// All windows of a display laid out side by side, so any of them, buried ones included, can be
/// picked by looking at it: big, separate tiles are what a gaze 2 cm off picks reliably.
public enum WindowOverview {
    /// Gap between tiles and around the grid, in points.
    static let spacing: CGFloat = 32
    /// Windows are never shown larger than this share of their real size.
    static let maximumScale: CGFloat = 0.8

    /// The display each window belongs to: the one holding most of it. Windows on no display are left out.
    public static func byDisplay(_ windows: [ScreenWindow], displays: [CGRect]) -> [[ScreenWindow]] {
        var result = [[ScreenWindow]](repeating: [], count: displays.count)
        for window in windows {
            let overlaps = displays.map { area(window.frame.intersection($0)) }
            guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else { continue }
            result[best].append(window)
        }
        return result
    }

    /// The order tiles are shown in: by app name, then each app's windows in the order they were
    /// opened. The same app lands in the same place every time, so the eyes learn where to go.
    /// Ordering by where windows sit, or by which was used last, reshuffles from one opening to
    /// the next: most windows are large and overlap, so their positions barely tell them apart.
    public static func ordered(_ windows: [ScreenWindow]) -> [ScreenWindow] {
        windows.sorted { a, b in
            switch a.appName.localizedStandardCompare(b.appName) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: (a.pid, a.id) < (b.pid, b.id)
            }
        }
    }

    /// A tile per window (same order as `windows`), in a grid filling `region` (global coordinates,
    /// lower-left origin), placed in reading order: rows top to bottom, tiles left to right. Tiles
    /// keep their window's shape.
    public static func layout(_ windows: [ScreenWindow], in region: CGRect) -> [CGRect] {
        guard !windows.isEmpty else { return [] }
        let bounds = region.insetBy(dx: spacing, dy: spacing)
        guard bounds.width > 0, bounds.height > 0 else { return windows.map { _ in .zero } }

        // The column count that shows the windows largest.
        func scales(columns: Int) -> (cell: CGSize, scales: [CGFloat]) {
            let rows = (windows.count + columns - 1) / columns
            let cell = CGSize(
                width: (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns),
                height: (bounds.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            )
            return (cell, windows.map { min(cell.width / $0.frame.width, cell.height / $0.frame.height, maximumScale) })
        }
        let columns = (1...windows.count).max { a, b in
            let shown = { (c: Int) in zip(windows, scales(columns: c).scales).reduce(0) { $0 + area($1.0.frame) * $1.1 * $1.1 } }
            return shown(a) < shown(b)
        }!
        let (cell, tileScales) = scales(columns: columns)

        let rows = stride(from: 0, to: windows.count, by: columns).map { start in
            Array(start..<min(start + columns, windows.count))
        }
        let gridHeight = CGFloat(rows.count) * cell.height + CGFloat(rows.count - 1) * spacing
        var tiles = [CGRect](repeating: .zero, count: windows.count)
        for (r, row) in rows.enumerated() {
            // Center short rows, and the grid vertically.
            let rowWidth = CGFloat(row.count) * cell.width + CGFloat(row.count - 1) * spacing
            let left = bounds.midX - rowWidth / 2
            let top = bounds.midY + gridHeight / 2 - CGFloat(r) * (cell.height + spacing)
            for (c, index) in row.enumerated() {
                let size = CGSize(width: windows[index].frame.width * tileScales[index], height: windows[index].frame.height * tileScales[index])
                let cellCenter = CGPoint(x: left + CGFloat(c) * (cell.width + spacing) + cell.width / 2, y: top - cell.height / 2)
                tiles[index] = CGRect(x: cellCenter.x - size.width / 2, y: cellCenter.y - size.height / 2, width: size.width, height: size.height)
            }
        }
        return tiles
    }

    /// Which tile the gaze picks: the nearest one, so looking at the gap beside a tile or just past
    /// its edge still counts. Tiles never overlap, so nearest is unambiguous. Gaze farther than
    /// `3 sigma` from every tile picks nothing. The current pick is kept until another tile is
    /// clearly nearer, so the highlight doesn't flicker while the gaze rests between two tiles.
    public static func pick(gaze: CGPoint, sigma: Double, tiles: [CGRect], current: Int?) -> Int? {
        let distances = tiles.map { distance(from: gaze, to: $0) }
        guard let best = distances.indices.min(by: { distances[$0] < distances[$1] }), distances[best] <= 3 * sigma else {
            return nil
        }
        // Less than the spacing between tiles, so entering a tile always selects it.
        let margin = min(0.3 * sigma, Double(spacing) * 0.75)
        if let current, current != best, current < distances.count, distances[current] - distances[best] < margin {
            return current
        }
        return best
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
