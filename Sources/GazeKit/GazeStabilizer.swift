import CoreGraphics
import Foundation

/// Turns noisy per-frame gaze points into a steady point that holds still while the eyes rest on
/// a spot (a fixation) and moves when they jump to a new one (a saccade).
///
/// Eyes don't glide; they rest, then jump. So rather than low-pass filtering (which either jitters
/// or lags), samples near the current fixation are averaged, single stray frames are ignored, and
/// the point moves once the last few frames, taken together, clearly sit somewhere else. Judging
/// frames together rather than one by one matters: with per-frame noise σ, a shift of 1.5σ is
/// invisible in any single frame but obvious in the median of eight. Short runs catch big jumps
/// quickly, longer runs catch small shifts, each tested against the noise expected for its length.
///
/// Head motion is measured far more precisely than the eyes, and is used two ways:
/// - **Quick shifts.** Large gaze shifts come with a head turn, so while the head moves, a far-off
///   new spot is accepted after two frames.
/// - **Following the head.** Moving the head while looking at one spot makes the eyes counter-rotate
///   and the gaze point stays put, which the fixation handles as is. But when the gaze is carried
///   along with the head (turning toward another screen), the point moves with the head. How much
///   of the head's motion the gaze is following is estimated from recent frames, and the fixation
///   is carried along by that share of the head's precise motion, instead of lagging and then
///   jumping on noisy iris readings.
public struct GazeStabilizer: Sendable {
    /// 0 = most responsive, 1 = steadiest.
    public var steadiness: Double

    private struct Sample {
        var point: CGPoint
        var time: TimeInterval
    }

    private var fixation: [Sample] = []
    /// The latest frames since the last jump, near the fixation or not.
    private var latest: [Sample] = []
    /// Running median distance (points) of samples from their fixation's center.
    private var medianDistance: Double = 40
    /// Per-frame scatter around a fixation, in points (standard deviation). For 2D Gaussian scatter
    /// the median distance from the center is about 1.18 σ. A median, unlike a mean, is barely
    /// affected by only seeing samples inside the radius, so the radius can't shrink itself away.
    var noise: Double { medianDistance / 1.1774 }

    /// Recent raw points alongside the accumulated head-driven shift, for estimating `carry`.
    private var recent: [(time: TimeInterval, point: CGPoint, head: CGPoint)] = []
    private var accumulatedHead = CGPoint.zero
    /// Share (0…1) of the head's motion the gaze is currently following: 0 = eyes hold a spot
    /// while the head moves, 1 = eyes still in the head, gaze carried along.
    private(set) var carry: Double = 0
    /// Smoothed head-driven shift per frame, in points.
    private var headStep: Double = 0

    public init(steadiness: Double = 0.5) {
        self.steadiness = steadiness
    }

    /// Samples within this distance (points) of the fixation count toward it; others are strays,
    /// or the start of a new fixation.
    var radius: Double { max(30, (2.5 + 1.5 * steadiness) * noise) }
    /// Fewest frames that can move the point to a new spot (with the head still).
    var framesToMove: Int { 2 + Int((2 * steadiness).rounded()) }
    /// Run lengths tested for a shift: short ones catch big jumps fast, long ones small shifts.
    var runLengths: [Int] { [framesToMove, 2 * framesToMove, 4 * framesToMove, 6 * framesToMove] }
    /// How many standard errors a run's median must be from the fixation to count as a shift.
    var shiftSignificance: Double { 3.4 + steadiness }
    /// While the head moves, two agreeing frames suffice for a shift this far (points): large gaze
    /// shifts come with head turns, while noise and small shifts stay close to the fixation.
    var quickJumpDistance: Double { 2 * radius }
    /// How far back (seconds) fixation samples are averaged; also lets the point follow slow drift.
    var window: TimeInterval { 0.3 + 1.2 * steadiness }
    /// Whether the head moves enough to shift the gaze point noticeably from frame to frame.
    var isHeadMoving: Bool { headStep > 0.4 * noise }

    static let carryWindow: TimeInterval = 0.4

    public mutating func reset() {
        fixation = []
        latest = []
        recent = []
        carry = 0
        headStep = 0
    }

    /// `headShift` is how far (points) the gaze point would have moved since the previous frame from
    /// the head's motion alone, with the eyes fixed in the head.
    public mutating func update(_ point: CGPoint, headShift: CGVector = .zero, at time: TimeInterval) -> CGPoint {
        // After a gap (face lost, blink run), start afresh rather than averaging across it.
        if let last = fixation.last, time - last.time > 0.5 {
            reset()
        }
        headStep = 0.6 * headStep + 0.4 * hypot(headShift.dx, headShift.dy)
        updateCarry(point, headShift: headShift, at: time)

        guard !fixation.isEmpty else {
            fixation = [Sample(point: point, time: time)]
            return point
        }

        // Carry the fixation (and any forming one) along with the share of head motion the gaze follows.
        let carried = CGVector(dx: carry * headShift.dx, dy: carry * headShift.dy)
        if carried != .zero {
            for i in fixation.indices { fixation[i].point += carried }
            for i in latest.indices { latest[i].point += carried }
        }

        let sample = Sample(point: point, time: time)
        latest.append(sample)
        if latest.count > runLengths.last! { latest.removeFirst() }
        if let run = shiftedRun() {
            // A new spot: jump there.
            fixation = run
            latest = []
            return Self.mean(fixation)
        }

        let center = Self.mean(fixation)
        let distance = hypot(point.x - center.x, point.y - center.y)
        if distance <= radius {
            fixation.append(sample)
            let oldest = time - window
            fixation.removeAll { $0.time < oldest }
            medianDistance = min(240, max(12, medianDistance * (distance > medianDistance ? 1.03 : 1 / 1.03)))
        }
        return Self.mean(fixation)
    }

    /// The latest run of frames that sits clearly away from the fixation before it, if any.
    private func shiftedRun() -> [Sample]? {
        // While the head moves, two frames agreeing on a far-off spot suffice.
        if isHeadMoving, latest.count >= 2 {
            let run = Array(latest.suffix(2))
            let target = Self.mean(run)
            let before = fixation.filter { $0.time < run[0].time }
            if !before.isEmpty, Self.distance(target, Self.mean(before)) > quickJumpDistance,
               Self.distance(run[0].point, run[1].point) <= radius {
                return run
            }
        }
        for length in runLengths where latest.count >= length {
            let run = Array(latest.suffix(length))
            // Compare with the fixation as it was before this run began.
            let before = fixation.filter { $0.time < run[0].time }
            guard before.count >= 3 else { continue }
            // Mean of the frames that agree with the run's median, so a stray frame can't fake a shift.
            let median = Self.median(run)
            let agreeing = run.filter { Self.distance($0.point, median) <= radius }
            guard agreeing.count * 3 >= length * 2 else { continue }
            let standardError = noise * (1 / Double(agreeing.count) + 1 / Double(before.count)).squareRoot()
            if Self.distance(Self.mean(agreeing), Self.mean(before)) > shiftSignificance * standardError {
                return agreeing
            }
        }
        return nil
    }

    /// Regresses the recent raw points on the accumulated head shift: a slope near 1 means the gaze
    /// moves with the head, near 0 that it holds still while the head moves. Only judged when the
    /// head moved well beyond the tracking noise in that time; otherwise eased back toward holding
    /// still, the safe assumption when motion starts.
    private mutating func updateCarry(_ point: CGPoint, headShift: CGVector, at time: TimeInterval) {
        accumulatedHead += headShift
        recent.append((time, point, accumulatedHead))
        recent.removeAll { $0.time < time - Self.carryWindow }
        guard recent.count >= 6 else {
            carry *= 0.9
            return
        }

        let n = Double(recent.count)
        let meanHead = recent.reduce(CGPoint.zero) { $0 + $1.head } / n
        let meanPoint = recent.reduce(CGPoint.zero) { $0 + $1.point } / n
        var covariance = 0.0, variance = 0.0
        for r in recent {
            let h = r.head - meanHead, p = r.point - meanPoint
            covariance += h.x * p.x + h.y * p.y
            variance += h.x * h.x + h.y * h.y
        }
        // The head's spread over the window must clearly exceed the per-frame noise.
        guard variance / n > pow(1.5 * noise, 2) else {
            carry *= 0.9
            return
        }
        // Only taken when it's clearly above zero, so noise alone doesn't read as the gaze following
        // the head (clamping at zero would otherwise keep only the noise that points that way).
        let standardError = noise / variance.squareRoot()
        let slope = covariance / variance
        let estimate = slope > 2 * standardError ? min(1, slope) : 0
        carry = 0.5 * carry + 0.5 * estimate
    }

    private static func mean(_ samples: [Sample]) -> CGPoint {
        samples.reduce(CGPoint.zero) { $0 + $1.point } / Double(samples.count)
    }

    private static func median(_ samples: [Sample]) -> CGPoint {
        GazeKit.median(samples.map(\.point))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func / (a: CGPoint, n: Double) -> CGPoint { CGPoint(x: a.x / n, y: a.y / n) }
    static func += (a: inout CGPoint, b: CGVector) { a = CGPoint(x: a.x + b.dx, y: a.y + b.dy) }
}
