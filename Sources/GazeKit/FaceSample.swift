import CoreGraphics
import Foundation
import simd

/// One eye as seen in a single camera frame.
///
/// Image-space points are normalized (0…1) with Vision's lower-left origin. "Eye space" (UV) is
/// defined by the two eye corners: `u` runs from the image-left corner (0) to the other (1), and `v`
/// is the signed perpendicular offset in units of eye width (positive = up in the image).
public struct EyeSample: Sendable, Equatable {
    public var contour: [CGPoint]
    public var contourUV: [CGPoint]
    public var iris: CGPoint
    public var irisUV: CGPoint
    /// Eye height divided by eye width. Drops sharply during blinks.
    public var openness: Double
    /// Whether `iris` came from our dark-pixel refinement rather than Vision's pupil landmark.
    public var irisRefined: Bool

    public init(contour: [CGPoint], contourUV: [CGPoint], iris: CGPoint, irisUV: CGPoint, openness: Double, irisRefined: Bool) {
        self.contour = contour
        self.contourUV = contourUV
        self.iris = iris
        self.irisUV = irisUV
        self.openness = openness
        self.irisRefined = irisRefined
    }
}

/// The raw 2D measurements behind a frame's 3D estimate, kept so calibration can redo the 3D
/// estimate with a different camera field of view.
public struct FaceMeasurements: Sendable, Equatable {
    public var timestamp: TimeInterval
    public var imageSize: SIMD2<Double>
    /// Pixel positions (lower-left origin) in `FaceShape.landmarks` order; `nil` where a landmark
    /// is out of view. The eye corners are always present.
    public var landmarks: [SIMD2<Double>?]
    public var irisImageLeft: SIMD2<Double>
    public var irisImageRight: SIMD2<Double>
    /// The gaze network's direction in camera space, when it ran on this frame.
    public var networkGaze: Vec3?
    /// The network's raw output behind `networkGaze`, for applying a per-user correction.
    public var networkReading: NetworkReading?

    public init(timestamp: TimeInterval, imageSize: SIMD2<Double>, landmarks: [SIMD2<Double>?], irisImageLeft: SIMD2<Double>, irisImageRight: SIMD2<Double>, networkGaze: Vec3? = nil) {
        self.timestamp = timestamp
        self.imageSize = imageSize
        self.landmarks = landmarks
        self.irisImageLeft = irisImageLeft
        self.irisImageRight = irisImageRight
        self.networkGaze = networkGaze
    }

    /// The network's gaze direction, with the user's correction applied when there is one.
    public func networkDirection(correction: FeatureCorrection?) -> Vec3? {
        guard let correction, let reading = networkReading else { return networkGaze }
        let angles = reading.angles + correction.correction(for: reading.features)
        return reading.normalization.gazeDirection(pitch: angles.x, yaw: angles.y)
    }

    /// `nil` if head pose can't be found, or `source` is the network and it didn't run on this frame.
    public func observe(fieldOfView: Double, face: FaceShape, source: GazeSource = .iris, correction: FeatureCorrection? = nil, using estimator: HeadPoseEstimator) -> (head: HeadPose, observation: GazeObservation)? {
        let intrinsics = CameraIntrinsics(imageWidth: imageSize.x, imageHeight: imageSize.y, horizontalFOVDegrees: fieldOfView)
        estimator.face = face
        guard let head = estimator.estimate(landmarks, intrinsics: intrinsics, time: timestamp) else { return nil }
        let observation = EyeModel.observation(
            head: head,
            face: face,
            corners: landmarks[0..<4].map { $0! },
            irisImageLeft: irisImageLeft,
            irisImageRight: irisImageRight,
            intrinsics: intrinsics
        )
        switch source {
        case .iris:
            return (head, observation)
        case .network:
            return networkDirection(correction: correction).map { (head, observation.withGaze($0)) }
        }
    }

    /// The 3D estimate with `model`'s camera, face, and gaze source.
    public func observe(for model: GazeModel, using estimator: HeadPoseEstimator) -> (head: HeadPose, observation: GazeObservation)? {
        observe(fieldOfView: model.fieldOfView, face: model.faceShape, source: model.gazeSource, correction: model.featureCorrection, using: estimator)
    }
}

/// What the gaze network made of a frame.
public struct NetworkReading: Sendable, Equatable {
    public var angles: SIMD2<Double>
    public var features: [Float]
    public var normalization: FaceNormalization

    public init(angles: SIMD2<Double>, features: [Float], normalization: FaceNormalization) {
        self.angles = angles
        self.features = features
        self.normalization = normalization
    }
}

/// A crop of the camera frame around the face.
public struct FaceImage: Sendable, Equatable {
    public var jpeg: Data
    /// The crop within the full frame, in pixels with a lower-left origin like the landmarks.
    public var rect: CGRect
}

/// Everything the face analyzer extracts from one camera frame.
public struct FaceSample: Sendable, Equatable {
    public static let blinkOpennessThreshold = 0.13

    public var timestamp: TimeInterval
    /// Normalized face bounding box (lower-left origin).
    public var faceBox: CGRect
    /// The user's right eye (on the image left, since the camera image is not mirrored).
    public var rightEye: EyeSample
    public var leftEye: EyeSample
    public var measurements: FaceMeasurements
    public var head: HeadPose
    public var observation: GazeObservation
    /// Only while recording calibration data.
    public var image: FaceImage?

    public init(timestamp: TimeInterval, faceBox: CGRect, rightEye: EyeSample, leftEye: EyeSample, measurements: FaceMeasurements, head: HeadPose, observation: GazeObservation, image: FaceImage? = nil) {
        self.timestamp = timestamp
        self.faceBox = faceBox
        self.rightEye = rightEye
        self.leftEye = leftEye
        self.measurements = measurements
        self.head = head
        self.observation = observation
        self.image = image
    }

    public var isBlinking: Bool {
        min(leftEye.openness, rightEye.openness) < Self.blinkOpennessThreshold
    }

    /// Good enough to learn from: eyes open, both irises found, every landmark in view, the face
    /// model fits the landmarks well, and the face is neither tiny nor huge in the frame.
    public var isReliable: Bool {
        guard !isBlinking, leftEye.irisRefined, rightEye.irisRefined,
              let outerLeft = measurements.landmarks[0], let outerRight = measurements.landmarks[3],
              measurements.landmarks.allSatisfy({ $0 != nil })
        else { return false }
        let eyeSpan = simd_length(outerRight - outerLeft)
        // Judged by the image rather than estimated distance, which the calibrated camera model skews.
        let spanFraction = eyeSpan / measurements.imageSize.x
        let yaw = abs(Rotation.headAngles(head.rotation).x)
        return head.fitError < eyeSpan * Self.maxRelativeFitError && (0.05...0.4).contains(spanFraction) && yaw < 0.6
    }

    /// Head-pose fit error, relative to the eye-corner span, beyond which a frame isn't trusted.
    public static let maxRelativeFitError = 0.08
}

extension [FaceSample] {
    /// Drops frames whose eye angles are far from the median: glances away, or bad detections.
    public func rejectingOutliers(threshold: Double = 3) -> [FaceSample] {
        guard count >= 5 else { return self }
        var keep = [Bool](repeating: true, count: count)
        for axis in 0..<2 {
            let column = map { $0.observation.eyeAngles[axis] }
            let med = median(column)
            let mad = Swift.max(median(column.map { abs($0 - med) }), 1e-4)
            for (i, value) in column.enumerated() where abs(value - med) / (1.4826 * mad) > threshold {
                keep[i] = false
            }
        }
        return zip(self, keep).filter(\.1).map(\.0)
    }
}

/// Why tracking is degraded or lost, in terms the user can act on.
public enum TrackingIssue: Sendable, Equatable {
    case noFace
    /// Part of the face is outside the camera's view, on the given side of the image.
    case partlyOutOfView(Edge)

    public enum Edge: Sendable {
        case top, bottom, left, right
    }

    public var message: String {
        switch self {
        case .noFace: "No face in view"
        case .partlyOutOfView(.top), .partlyOutOfView(.bottom): "Face partly out of view. Lean back a little."
        case .partlyOutOfView(.left), .partlyOutOfView(.right): "Face partly out of view. Move toward the middle."
        }
    }
}

/// The analyzer's verdict on one frame. A frame can be tracked and still have an issue, e.g. when
/// the mouth is out of view and head pose comes from the eyes and nose alone.
public struct FrameAnalysis: Sendable {
    public var sample: FaceSample?
    public var issue: TrackingIssue?

    public init(sample: FaceSample?, issue: TrackingIssue?) {
        self.sample = sample
        self.issue = issue
    }
}
