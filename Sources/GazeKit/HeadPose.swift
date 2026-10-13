import Foundation
import simd

/// Head position and orientation in camera space.
///
/// The head frame matches camera space when facing the camera head-on: +x toward the image right
/// (the user's left), +y up, +z into the head. A head-frame point maps to camera space as `R·p + t`.
public struct HeadPose: Sendable, Equatable {
    public var rotation: simd_double3x3
    public var translation: Vec3
    /// RMS distance in pixels between the detected landmarks and the fitted face model's projection.
    public var fitError: Double

    public init(rotation: simd_double3x3, translation: Vec3, fitError: Double = 0) {
        self.rotation = rotation
        self.translation = translation
        self.fitError = fitError
    }

    public func toCamera(_ p: Vec3) -> Vec3 {
        rotation * p + translation
    }
}

/// A face's 3D landmark positions in millimeters in the head frame, origin at the nose tip.
///
/// Faces differ by several millimeters (nose prominence, eye spacing, mouth height), and fitting
/// head pose against the wrong shape misreads head turns by several degrees, more the further the
/// head turns. Calibration therefore learns the user's own shape from how their landmarks move as
/// the head moves (`fit`), starting from and staying near a generic adult face.
public struct FaceShape: Sendable, Codable, Equatable {
    /// In the order of `HeadPoseEstimator.estimate`'s points: outer and inner corner of the eye on the
    /// image left, inner and outer corner of the other eye, nose tip, mouth corners (image left, right).
    public var landmarks: [Vec3]
    /// How far (mm) the eyeballs' centers of rotation sit behind the midpoint of each eye's corners.
    ///
    /// Turning the head moves the iris relative to the eye corners by this lever, and that has to be
    /// subtracted to get the eye's own rotation. From one camera, a deep face turning a little looks
    /// like a shallow face turning a lot, so the head pose's turn angles carry a per-user scale error;
    /// fitting this lever during calibration (where the user looks at a dot while turning their head)
    /// takes up both that and the user's actual eye anatomy.
    public var eyeballDepth: Double

    public init(landmarks: [Vec3], eyeballDepth: Double = 6) {
        self.landmarks = landmarks
        self.eyeballDepth = eyeballDepth
    }

    public static let generic = FaceShape(landmarks: [
        Vec3(-47, 36, 30), // outer corner, eye on the image left
        Vec3(-16, 35, 22), // inner corner, eye on the image left
        Vec3(16, 35, 22), // inner corner, eye on the image right
        Vec3(47, 36, 30), // outer corner, eye on the image right
        Vec3(0, 0, 0), // nose tip
        Vec3(-25, -30, 22), // mouth corner, image left
        Vec3(25, -30, 22), // mouth corner, image right
    ])

    public var eyeballCenterImageLeft: Vec3 { (landmarks[0] + landmarks[1]) / 2 + Vec3(0, 0, eyeballDepth) }
    public var eyeballCenterImageRight: Vec3 { (landmarks[2] + landmarks[3]) / 2 + Vec3(0, 0, eyeballDepth) }
    var outerCornerDistance: Double { simd_length(landmarks[3] - landmarks[0]) }
}

/// Solves the perspective-n-point problem for a `FaceShape` with Levenberg–Marquardt,
/// warm-started from the previous frame.
///
/// Not thread-safe; call from a single serial queue.
public final class HeadPoseEstimator: @unchecked Sendable {
    private var previous: (pose: HeadPose, rotationVector: Vec3, time: TimeInterval)?

    /// The face being tracked. Changing it restarts tracking.
    public var face: FaceShape {
        didSet { if face != oldValue { previous = nil } }
    }

    public init(face: FaceShape = .generic) {
        self.face = face
    }

    /// `points` are pixel positions (lower-left origin) in `FaceShape.landmarks` order, `nil` for
    /// landmarks that aren't visible (e.g. the mouth when leaning in close). The four eye corners
    /// are required.
    ///
    /// A nose or mouth point that disagrees sharply with the rest (Vision occasionally misplaces
    /// one by tens of pixels for a frame) is dropped and the pose refitted without it.
    public func estimate(_ points: [SIMD2<Double>?], intrinsics: CameraIntrinsics, time: TimeInterval) -> HeadPose? {
        estimate(points, intrinsics: intrinsics, time: time, rejectsOutliers: true)
    }

    private func estimate(_ points: [SIMD2<Double>?], intrinsics: CameraIntrinsics, time: TimeInterval, rejectsOutliers: Bool) -> HeadPose? {
        guard points.count == face.landmarks.count,
              let outerLeft = points[0], let outerRight = points[3], points[1] != nil, points[2] != nil
        else { return nil }
        let visible = zip(face.landmarks, points).compactMap { model, observed in observed.map { (model, $0) } }

        let recent = previous.flatMap { time - $0.time < 0.3 ? $0 : nil }
        // Six unknowns: from a standing start, need the nose (or more) beyond the near-collinear eye corners.
        guard visible.count >= (recent == nil ? 5 : 4) else { return nil }

        let initial: [Double]
        if let recent {
            let r = recent.rotationVector, t = recent.pose.translation
            initial = [r.x, r.y, r.z, t.x, t.y, t.z]
        } else {
            initial = coldStart(outerLeft: outerLeft, outerRight: outerRight, intrinsics: intrinsics)
        }
        // The eye corners alone are nearly collinear and leave the head's pitch undetermined, so
        // with nothing else visible lean slightly on the previous pose. Any one more point suffices.
        let prior = visible.count <= 4 ? recent.map { _ in initial } : nil

        func residuals(_ p: [Double]) -> [Double] {
            let pose = Self.pose(p)
            var residuals: [Double] = []
            residuals.reserveCapacity(visible.count * 2 + 6)
            for (model, observed) in visible {
                let c = pose.toCamera(model)
                guard c.z > 1 else { return [Double](repeating: 1e4, count: visible.count * 2 + (prior == nil ? 0 : 6)) }
                let projected = intrinsics.project(c)
                residuals.append(projected.x - observed.x)
                residuals.append(projected.y - observed.y)
            }
            if let prior {
                // Pixels per radian and per millimeter: a 0.02 rad or 50 mm change costs about one pixel.
                residuals += (0..<3).map { 50 * (p[$0] - prior[$0]) }
                residuals += (3..<6).map { 0.02 * (p[$0] - prior[$0]) }
            }
            return residuals
        }

        let solution = LeastSquares.minimize(initial, steps: [1e-4, 1e-4, 1e-4, 1e-2, 1e-2, 1e-2], iterations: 20, residuals: residuals)
        var pose = Self.pose(solution)
        let r = residuals(solution).prefix(visible.count * 2)
        pose.fitError = (r.reduce(0) { $0 + $1 * $1 } / Double(visible.count)).squareRoot()
        // A sanity bound against a diverged fit, not a distance limit: the calibrated camera model
        // can read depth well below the true distance.
        guard pose.translation.z > 30, pose.translation.z < 3000 else {
            previous = nil
            return nil
        }
        let span = simd_length(outerRight - outerLeft)
        if rejectsOutliers, pose.fitError > Self.outlierFitError * span, let refit = refitWithoutOutlier(points, pose: pose, intrinsics: intrinsics, time: time, span: span) {
            return refit
        }
        previous = (pose, Vec3(solution[0], solution[1], solution[2]), time)
        return pose
    }

    /// Fit error (relative to the eye-corner span) above which a misplaced landmark is looked for.
    static let outlierFitError = 0.02

    /// A misplaced nose or mouth point drags the whole pose, so its own error doesn't stand out
    /// from the others'. Instead, refit without each in turn and keep the refit that both fits the
    /// rest well and puts the dropped point far off.
    private func refitWithoutOutlier(_ points: [SIMD2<Double>?], pose: HeadPose, intrinsics: CameraIntrinsics, time: TimeInterval, span: Double) -> HeadPose? {
        let saved = previous
        var best: (pose: HeadPose, state: (pose: HeadPose, rotationVector: Vec3, time: TimeInterval)?)?
        for index in 4..<points.count where points[index] != nil {
            var kept = points
            kept[index] = nil
            previous = saved
            guard let refit = estimate(kept, intrinsics: intrinsics, time: time, rejectsOutliers: false) else { continue }
            let dropped = simd_length(intrinsics.project(refit.toCamera(face.landmarks[index])) - points[index]!)
            guard refit.fitError < 0.5 * pose.fitError, dropped > 0.06 * span else { continue }
            if best == nil || refit.fitError < best!.pose.fitError {
                best = (refit, previous)
            }
        }
        previous = best?.state ?? saved
        return best?.pose
    }

    /// Facing the camera, rolled to match the eye line, at the depth implied by the eye-corner spacing.
    private func coldStart(outerLeft: SIMD2<Double>, outerRight: SIMD2<Double>, intrinsics: CameraIntrinsics) -> [Double] {
        let span = simd_length(outerRight - outerLeft)
        let depth = intrinsics.focalLength * face.outerCornerDistance / max(span, 1)
        let mid = (outerLeft + outerRight) / 2
        let ray = intrinsics.ray(through: mid)
        let eyeMid = ray * (depth / ray.z)
        let roll = atan2(outerRight.y - outerLeft.y, outerRight.x - outerLeft.x)
        let rotation = Rotation.matrix(Vec3(0, 0, roll))
        let t = eyeMid - rotation * ((face.landmarks[0] + face.landmarks[3]) / 2)
        return [0, 0, roll, t.x, t.y, t.z]
    }

    private static func pose(_ p: [Double]) -> HeadPose {
        HeadPose(rotation: Rotation.matrix(Vec3(p[0], p[1], p[2])), translation: Vec3(p[3], p[4], p[5]))
    }
}

extension FaceShape {
    /// Learns the user's face shape from frames with every landmark visible, by alternating
    /// between estimating each frame's head pose against the current shape and re-solving each
    /// landmark's 3D position against those poses. A landmark only moves from the generic position
    /// as far as the head motion in the frames can pin it down.
    ///
    /// The overall size can't be told apart from distance with one camera, so it stays generic.
    public static func fit(_ frames: [FaceMeasurements], fieldOfView: Double, rounds: Int = 6) -> FaceShape {
        let frames = frames
            .filter { $0.landmarks.allSatisfy { $0 != nil } }
            .sorted { $0.timestamp < $1.timestamp }
        guard frames.count >= minimumFrames else { return .generic }

        var shape = FaceShape.generic
        for _ in 0..<rounds {
            let estimator = HeadPoseEstimator(face: shape)
            var views: [(pose: HeadPose, intrinsics: CameraIntrinsics, points: [SIMD2<Double>])] = []
            for frame in frames {
                let intrinsics = CameraIntrinsics(imageWidth: frame.imageSize.x, imageHeight: frame.imageSize.y, horizontalFOVDegrees: fieldOfView)
                guard let pose = estimator.estimate(frame.landmarks, intrinsics: intrinsics, time: frame.timestamp) else { continue }
                let points = frame.landmarks.map { $0! }
                // Skip frames where the landmarks clearly weren't of a rigid face (mid-expression, misdetected).
                guard pose.fitError < 0.15 * simd_length(points[3] - points[0]) else { continue }
                views.append((pose, intrinsics, points))
            }
            guard views.count >= minimumFrames else { return shape }

            let landmarks = shape.landmarks.indices.map { j -> Vec3 in
                let start = shape.landmarks[j], prior = generic.landmarks[j]
                let p = LeastSquares.minimize([start.x, start.y, start.z], steps: [1e-3, 1e-3, 1e-3], iterations: 10) { q in
                    let point = Vec3(q[0], q[1], q[2])
                    var r: [Double] = []
                    r.reserveCapacity(views.count * 2 + 3)
                    for view in views {
                        let c = view.pose.toCamera(point)
                        let projected = view.intrinsics.project(c)
                        r.append(projected.x - view.points[j].x)
                        r.append(projected.y - view.points[j].y)
                    }
                    r += (0..<3).map { priorWeight * (q[$0] - prior[$0]) }
                    return r
                }
                return Vec3(p[0], p[1], p[2])
            }
            shape = FaceShape(landmarks: landmarks, eyeballDepth: shape.eyeballDepth).aligned(to: generic)
        }
        return shape
    }

    static let minimumFrames = 30
    /// Pixel-equivalent cost per millimeter away from the generic face, per coordinate. Small head
    /// turns leave the face's depth relief poorly determined, so this matters; the depth that's
    /// left uncertain is taken up by `eyeballDepth`.
    static let priorWeight = 3.0

    /// This shape moved, turned, and scaled to best match `reference`, with the nose tip at the origin,
    /// so the head frame keeps its meaning (forward is −z, up is +y) and the overall size its value.
    func aligned(to reference: FaceShape) -> FaceShape {
        let nose = landmarks[4]
        var points = landmarks.map { $0 - nose }
        let size = { (p: [Vec3]) in (p.reduce(0) { $0 + simd_length_squared($1) } / Double(p.count)).squareRoot() }
        let scale = size(reference.landmarks) / max(size(points), 1e-9)
        points = points.map { $0 * scale }
        let r = LeastSquares.minimize([0, 0, 0], steps: [1e-5, 1e-5, 1e-5], iterations: 20) { q in
            let m = Rotation.matrix(Vec3(q[0], q[1], q[2]))
            return zip(points, reference.landmarks).flatMap { p, g -> [Double] in
                let d = m * p - g
                return [d.x, d.y, d.z]
            }
        }
        let m = Rotation.matrix(Vec3(r[0], r[1], r[2]))
        return FaceShape(landmarks: points.map { m * $0 }, eyeballDepth: eyeballDepth)
    }
}
