import CoreGraphics
import Foundation

/// The paths of the calibration dot the eyes follow, slow enough for smooth pursuit (about 10° a
/// second).
public enum PursuitPath {
    public enum Kind: Sendable {
        /// A Lissajous figure (two sweeps across, three up and down) through the whole screen.
        case sweep
        /// A rounded-rectangle lap along the edges and into the corners (where estimates are least
        /// accurate, and where the sweep doesn't quite reach), then one spiraling inward.
        case loops
    }

    public static func duration(_ kind: Kind) -> TimeInterval {
        switch kind {
        case .sweep: 18
        case .loops: 15
        }
    }

    /// How far toward the edges the sweep goes, as a share of the half-size.
    static let reach = 0.88
    /// The loops' inset from the screen's edges, as a share of its size, at the start and the end.
    static let loopInset = (outer: 0.05, inner: 0.3)

    /// Where the dot is `t` seconds after it starts, in `frame` (global AppKit coordinates).
    public static func point(_ kind: Kind, in frame: CGRect, at t: TimeInterval) -> CGPoint {
        let progress = min(max(t, 0), duration(kind)) / duration(kind)
        // (x, y) as shares of the frame from its top-left.
        let relative: (Double, Double)
        switch kind {
        case .sweep:
            let phase = 2 * Double.pi * progress
            relative = (0.5 + reach / 2 * sin(2 * phase), 0.5 + reach / 2 * sin(3 * phase + .pi / 2))
        case .loops:
            // The first lap along the edges, the second spiraling inward.
            let lap = progress * 2
            let inset = loopInset.outer + (loopInset.inner - loopInset.outer) * max(0, lap - 1)
            relative = roundedRectangle(width: frame.width, height: frame.height, inset: inset, at: lap.truncatingRemainder(dividingBy: 1))
        }
        return CGPoint(x: frame.minX + frame.width * relative.0, y: frame.maxY - frame.height * relative.1)
    }

    /// A point `fraction` of the way around a rounded rectangle inset by `inset` (shares of each
    /// side), clockwise from the top middle at even speed, as shares of a `width` × `height` frame
    /// from its top-left.
    static func roundedRectangle(width: Double, height: Double, inset: Double, at fraction: Double) -> (Double, Double) {
        let w = width * (1 - 2 * inset), h = height * (1 - 2 * inset)
        let r = 0.1 * min(w, h)
        let straight = (w - 2 * r, h - 2 * r)
        let arc = Double.pi / 2 * r
        // Top half, right side, bottom, left side, top half again, with a quarter circle between each.
        let pieces: [(length: Double, at: (Double) -> (Double, Double))] = [
            (straight.0 / 2, { (w / 2 + $0, 0) }),
            (arc, { a in let angle = a / r; return (w - r + r * sin(angle), r - r * cos(angle)) }),
            (straight.1, { (w, r + $0) }),
            (arc, { a in let angle = a / r; return (w - r + r * cos(angle), h - r + r * sin(angle)) }),
            (straight.0, { (w - r - $0, h) }),
            (arc, { a in let angle = a / r; return (r - r * sin(angle), h - r + r * cos(angle)) }),
            (straight.1, { (0, h - r - $0) }),
            (arc, { a in let angle = a / r; return (r - r * cos(angle), r - r * sin(angle)) }),
            (straight.0 / 2, { (r + $0, 0) }),
        ]
        var distance = fraction * pieces.reduce(0) { $0 + $1.length }
        var local = (w / 2, 0.0)
        for piece in pieces {
            if distance <= piece.length {
                local = piece.at(distance)
                break
            }
            distance -= piece.length
        }
        return ((width * inset + local.0) / width, (height * inset + local.1) / height)
    }
}
