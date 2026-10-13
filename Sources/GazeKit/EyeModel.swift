import Foundation
import simd

/// What one frame says about gaze, before per-user calibration.
public struct GazeObservation: Sendable, Equatable {
    /// Midpoint between the two eyeball centers, in camera millimeters.
    public var origin: Vec3
    public var headRotation: simd_double3x3
    /// Eye-in-head yaw and pitch in radians, averaged over both eyes. Zero = looking straight ahead
    /// from the face. Positive yaw is toward the image right, positive pitch is up.
    public var eyeAngles: SIMD2<Double>

    public init(origin: Vec3, headRotation: simd_double3x3, eyeAngles: SIMD2<Double>) {
        self.origin = origin
        self.headRotation = headRotation
        self.eyeAngles = eyeAngles
    }

    /// The same head, with the eyes pointing along a camera-space direction.
    public func withGaze(_ direction: Vec3) -> GazeObservation {
        var o = self
        o.eyeAngles = EyeModel.angles(ofHeadDirection: headRotation.transpose * direction)
        return o
    }
}

/// Eyeball geometry: the iris is a point on a sphere around the eyeball center.
public enum EyeModel {
    /// Distance from the eyeball center to the iris center, in millimeters.
    public static let irisRadius = 10.0

    /// Builds an observation from the head pose, each eye's two corners, and both irises' pixel
    /// positions. Corners are in `FaceShape.landmarks` order: outer and inner of the image-left eye,
    /// then inner and outer of the other.
    public static func observation(
        head: HeadPose,
        face: FaceShape,
        corners: [SIMD2<Double>],
        irisImageLeft: SIMD2<Double>,
        irisImageRight: SIMD2<Double>,
        intrinsics: CameraIntrinsics
    ) -> GazeObservation {
        let centerLeft = eyeballCenter(head: head, model: face.eyeballCenterImageLeft, corners: (corners[0], corners[1]), modelCorners: (face.landmarks[0], face.landmarks[1]), intrinsics: intrinsics)
        let centerRight = eyeballCenter(head: head, model: face.eyeballCenterImageRight, corners: (corners[3], corners[2]), modelCorners: (face.landmarks[3], face.landmarks[2]), intrinsics: intrinsics)
        let toHead = head.rotation.transpose
        let anglesLeft = angles(ofHeadDirection: toHead * opticalAxis(eyeCenter: centerLeft, irisPixel: irisImageLeft, intrinsics: intrinsics))
        let anglesRight = angles(ofHeadDirection: toHead * opticalAxis(eyeCenter: centerRight, irisPixel: irisImageRight, intrinsics: intrinsics))
        return GazeObservation(
            origin: (centerLeft + centerRight) / 2,
            headRotation: head.rotation,
            eyeAngles: (anglesLeft + anglesRight) / 2
        )
    }

    /// The eyeball center, pinned to where that eye's corners actually are in the image.
    ///
    /// The iris sits only 10 mm from the eyeball center, so a millimeter of error in the center is
    /// several degrees of gaze. Placing the center by the whole-face pose would carry over every way
    /// the user's face differs from the generic model (nose length, mouth position), and those errors
    /// change as the head turns. The eye's own corners are right next to it: take the depth and
    /// orientation from the head pose, but the position across the image from the corners.
    static func eyeballCenter(
        head: HeadPose,
        model: Vec3,
        corners: (outer: SIMD2<Double>, inner: SIMD2<Double>),
        modelCorners: (outer: Vec3, inner: Vec3),
        intrinsics: CameraIntrinsics
    ) -> Vec3 {
        let modelMid = (modelCorners.outer + modelCorners.inner) / 2
        let depth = head.toCamera(modelMid).z
        let ray = intrinsics.ray(through: (corners.outer + corners.inner) / 2)
        let observedMid = ray * (depth / ray.z)
        return observedMid + head.rotation * (model - modelMid)
    }

    /// Direction from the eyeball center through the iris, found by intersecting the camera ray
    /// through the iris pixel with the eyeball sphere (nearest intersection, facing the camera).
    public static func opticalAxis(eyeCenter c: Vec3, irisPixel: SIMD2<Double>, intrinsics: CameraIntrinsics) -> Vec3 {
        let d = intrinsics.ray(through: irisPixel)
        let b = simd_dot(d, c)
        let discriminant = b * b - (simd_dot(c, c) - irisRadius * irisRadius)
        // If the ray misses (noisy iris or eyeball estimate), use the closest point on the ray.
        let s = discriminant > 0 ? b - discriminant.squareRoot() : b
        return simd_normalize(d * s - c)
    }

    /// Head-frame direction → (yaw, pitch). Looking out of the face is −z in the head frame.
    public static func angles(ofHeadDirection d: Vec3) -> SIMD2<Double> {
        SIMD2(atan2(d.x, -d.z), atan2(d.y, -d.z))
    }

    public static func direction(fromAngles a: SIMD2<Double>) -> Vec3 {
        simd_normalize(Vec3(tan(a.x), tan(a.y), -1))
    }
}

extension GazeObservation: Codable {
    private enum CodingKeys: String, CodingKey {
        case origin, headRotation, eyeAngles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let m = try container.decode([Double].self, forKey: .headRotation)
        guard m.count == 9 else {
            throw DecodingError.dataCorruptedError(forKey: .headRotation, in: container, debugDescription: "Expected 9 values")
        }
        self.init(
            origin: try container.decode(Vec3.self, forKey: .origin),
            headRotation: simd_double3x3(columns: (Vec3(m[0], m[1], m[2]), Vec3(m[3], m[4], m[5]), Vec3(m[6], m[7], m[8]))),
            eyeAngles: try container.decode(SIMD2<Double>.self, forKey: .eyeAngles)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin, forKey: .origin)
        let c = headRotation.columns
        try container.encode([c.0.x, c.0.y, c.0.z, c.1.x, c.1.y, c.1.z, c.2.x, c.2.y, c.2.z], forKey: .headRotation)
        try container.encode(eyeAngles, forKey: .eyeAngles)
    }
}
