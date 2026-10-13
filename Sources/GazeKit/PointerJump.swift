import CoreGraphics
import Foundation

/// Gaze-assisted pointing (MAGIC pointing, Zhai et al. 1999): when the hand starts moving the
/// mouse toward where the eyes are, the pointer jumps most of the way there and the hand does the
/// precise rest. Gaze only needs to be roughly right for that.
public enum PointerJump {
    /// Mouse travel before deciding, so the direction of the movement is known.
    public static let decisionDistance = 12.0
    /// The movement must head this close to the gaze direction (degrees).
    public static let maximumAngle = 50.0

    /// Whether a mouse movement that began at `start` and is now at `current` should jump to
    /// `gaze`. `distance` is the minimum gap (points) between pointer and gaze worth jumping:
    /// a short move is quicker by hand, and a jump into the gaze's own error helps nobody.
    public static func shouldJump(from start: CGPoint, to current: CGPoint, gaze: CGPoint, minimumDistance: Double, decisionDistance: Double = decisionDistance, maximumAngle: Double = maximumAngle) -> Bool {
        let move = CGVector(dx: current.x - start.x, dy: current.y - start.y)
        let toGaze = CGVector(dx: gaze.x - start.x, dy: gaze.y - start.y)
        let moved = hypot(move.dx, move.dy)
        let gap = hypot(toGaze.dx, toGaze.dy)
        guard moved >= decisionDistance, gap >= minimumDistance else { return false }
        let cosine = (move.dx * toGaze.dx + move.dy * toGaze.dy) / (moved * gap)
        return cosine >= cos(maximumAngle * .pi / 180)
    }
}
