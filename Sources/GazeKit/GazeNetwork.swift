import CoreML
import CoreVideo
import Foundation
import os
import simd

/// Where a frame's eye-in-head direction comes from.
public enum GazeSource: String, Sendable, Codable, CaseIterable {
    /// The geometric model: iris position on an eyeball sphere.
    case iris
    /// An appearance-based neural network looking at the whole face (ETH-XGaze, ResNet-18).
    case network

    public var label: String {
        switch self {
        case .iris: "Iris geometry"
        case .network: "Neural network"
        }
    }
}

/// Zhang et al.'s data normalization ("Revisiting Data Normalization for Appearance-Based Gaze
/// Estimation", 2018), which the network was trained with: a virtual camera looks straight at the
/// face center from a fixed distance, with the head's roll removed, so the network only has to deal
/// with gaze and the remaining head yaw and pitch.
///
/// Computed in OpenCV's camera convention (+y down, pixels from the top-left) like the training data,
/// and converted from and to ours (+y up, pixels from the bottom-left) at the edges.
public struct FaceNormalization: Sendable, Equatable {
    public static let patchSize = 224
    /// The normalized camera's focal length (pixels) and distance from the face (mm) used by ETH-XGaze.
    static let focalLength = 960.0
    static let distance = 600.0

    /// Rows are the normalized camera's axes in (OpenCV) camera space.
    let rotation: simd_double3x3
    /// The face center the virtual camera looks at, in our camera space (mm).
    public let center: Vec3
    /// Maps a normalized patch pixel (top-left origin, homogeneous) to a source image pixel (top-left origin).
    let patchToImage: simd_double3x3

    public init?(head: HeadPose, face: FaceShape, intrinsics: CameraIntrinsics, imageHeight: Double) {
        // ETH-XGaze centers on the midpoint between the eyes' center and the nostrils.
        let eyes = (face.landmarks[0] + face.landmarks[1] + face.landmarks[2] + face.landmarks[3]) / 4
        let nostrils = face.landmarks[4] + Vec3(0, -5, 12)
        let faceCenter = head.toCamera((eyes + nostrils) / 2)
        let center = Self.flip(faceCenter)
        let headX = Self.flip(head.rotation * Vec3(1, 0, 0))
        let d = simd_length(center)
        guard d > 100 else { return nil }

        let z = center / d
        let y = simd_normalize(simd_cross(z, headX))
        let x = simd_normalize(simd_cross(y, z))
        // simd matrices are column-major: build from columns, then transpose to get rows x, y, z.
        let rotation = simd_double3x3(columns: (x, y, z)).transpose

        let f = intrinsics.focalLength
        let camera = simd_double3x3(rows: [
            Vec3(f, 0, intrinsics.center.x),
            Vec3(0, f, imageHeight - intrinsics.center.y),
            Vec3(0, 0, 1),
        ])
        let half = Double(Self.patchSize) / 2
        let normalizedCamera = simd_double3x3(rows: [
            Vec3(Self.focalLength, 0, half),
            Vec3(0, Self.focalLength, half),
            Vec3(0, 0, 1),
        ])
        let scale = simd_double3x3(diagonal: Vec3(1, 1, Self.distance / d))
        let imageToPatch = normalizedCamera * scale * rotation * camera.inverse
        self.rotation = rotation
        self.center = faceCenter
        patchToImage = imageToPatch.inverse
    }

    /// The network's (pitch, yaw) in the normalized camera → a unit gaze direction in our camera space.
    public func gazeDirection(pitch: Double, yaw: Double) -> Vec3 {
        // MPIIGaze/ETH-XGaze convention: the angles describe the vector from the target to the face.
        let normalized = -Vec3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        return simd_normalize(Self.flip(rotation.transpose * normalized))
    }

    /// The inverse of `gazeDirection`: (pitch, yaw) for a camera-space direction.
    public func angles(of direction: Vec3) -> SIMD2<Double> {
        let n = -(rotation * Self.flip(simd_normalize(direction)))
        return SIMD2(asin(n.y), atan2(n.x, n.z))
    }

    /// Source pixel (top-left origin) for a patch pixel center.
    func imagePoint(patchX: Double, patchY: Double) -> SIMD2<Double> {
        let p = patchToImage * Vec3(patchX, patchY, 1)
        return SIMD2(p.x / p.z, p.y / p.z)
    }

    /// Our camera space ↔ OpenCV's: the y axis points the other way.
    static func flip(_ v: Vec3) -> Vec3 { Vec3(v.x, -v.y, v.z) }
}

/// Saved with learning samples, to turn the network's angles into a direction again later. Only
/// the rotation and center are kept: rendering patches, which needs the rest, never happens on a
/// saved normalization.
extension FaceNormalization: Codable {
    private enum CodingKeys: String, CodingKey {
        case rotation, center
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let m = try c.decode([Double].self, forKey: .rotation)
        guard m.count == 9 else {
            throw DecodingError.dataCorruptedError(forKey: .rotation, in: c, debugDescription: "Expected 9 values")
        }
        rotation = simd_double3x3(rows: [Vec3(m[0], m[1], m[2]), Vec3(m[3], m[4], m[5]), Vec3(m[6], m[7], m[8])])
        center = try c.decode(Vec3.self, forKey: .center)
        patchToImage = matrix_identity_double3x3
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let r = rotation.transpose.columns
        try c.encode([r.0.x, r.0.y, r.0.z, r.1.x, r.1.y, r.1.z, r.2.x, r.2.y, r.2.z], forKey: .rotation)
        try c.encode(center, forKey: .center)
    }
}

/// Runs the gaze network on a camera frame.
///
/// Not thread-safe; call from a single serial queue.
public final class GazeNetwork: @unchecked Sendable {
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private var patch: CVPixelBuffer?
    private var mirroredPatch: CVPixelBuffer?
    /// Also runs on the mirrored face and averages the two (yaw flipped back), which cancels part
    /// of the network's per-frame noise at twice the cost.
    public var averagesMirrored = false

    /// Whether a model is installed, without loading it. Checked once: views read it on every redraw.
    public static let isInstalled = !modelURLs().isEmpty

    /// The compiled model bundled with the app, or a model placed in Application Support for development.
    public static func load() -> GazeNetwork? {
        for url in modelURLs() {
            if let network = try? GazeNetwork(url: url) { return network }
        }
        return nil
    }

    private static func modelURLs() -> [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Gaze/Models", isDirectory: true)
        let candidates = [
            Bundle.main.url(forResource: "GazeNet", withExtension: "mlmodelc"),
            support?.appendingPathComponent("GazeNet.mlmodelc"),
            support?.appendingPathComponent("GazeNet.mlpackage"),
        ]
        return candidates.compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public init(url: URL) throws {
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: compiled, configuration: configuration)
        let description = model.modelDescription
        guard let input = description.inputDescriptionsByName.first(where: { $0.value.type == .image })?.key,
              let output = description.outputDescriptionsByName["gaze"] != nil ? "gaze"
                : description.outputDescriptionsByName.first(where: { $0.value.type == .multiArray })?.key
        else { throw CocoaError(.fileReadCorruptFile) }
        inputName = input
        outputName = output
    }

    /// What the network makes of one frame.
    public struct Estimate {
        public var normalization: FaceNormalization
        /// (pitch, yaw) in the normalized camera, radians.
        public var angles: SIMD2<Double>
        /// What the final layer reads, when the model provides it.
        public var features: [Float]?

        public var direction: Vec3 { normalization.gazeDirection(pitch: angles.x, yaw: angles.y) }
    }

    /// Gaze direction in camera space, or `nil` if the frame can't be normalized or the model fails.
    public func gaze(in frame: CVPixelBuffer, head: HeadPose, face: FaceShape, intrinsics: CameraIntrinsics) -> Vec3? {
        estimate(in: frame, head: head, face: face, intrinsics: intrinsics)?.direction
    }

    public func estimate(in frame: CVPixelBuffer, head: HeadPose, face: FaceShape, intrinsics: CameraIntrinsics) -> Estimate? {
        let height = Double(CVPixelBufferGetHeight(frame))
        guard let normalization = FaceNormalization(head: head, face: face, intrinsics: intrinsics, imageHeight: height),
              let patch = Self.buffer(&patch),
              PatchRenderer.render(frame, into: patch, normalization: normalization),
              var result = predict(patch)
        else { return nil }
        if averagesMirrored, let mirrored = Self.buffer(&mirroredPatch) {
            PatchRenderer.mirror(patch, into: mirrored)
            if let other = predict(mirrored) {
                result.angles = SIMD2((result.angles.x + other.angles.x) / 2, (result.angles.y - other.angles.y) / 2)
            }
        }
        return Estimate(normalization: normalization, angles: result.angles, features: result.features)
    }

    private func predict(_ patch: CVPixelBuffer) -> (angles: SIMD2<Double>, features: [Float]?)? {
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: patch)]),
              let output = try? model.prediction(from: input),
              let result = output.featureValue(for: outputName)?.multiArrayValue,
              result.count >= 2
        else { return nil }
        let pitch = result[0].doubleValue, yaw = result[1].doubleValue
        guard pitch.isFinite, yaw.isFinite else { return nil }
        let features = output.featureValue(for: "features")?.multiArrayValue.map { array in
            (0..<array.count).map { array[$0].floatValue }
        }
        return (SIMD2(pitch, yaw), features)
    }

    private static func buffer(_ cached: inout CVPixelBuffer?) -> CVPixelBuffer? {
        if let cached { return cached }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        CVPixelBufferCreate(nil, FaceNormalization.patchSize, FaceNormalization.patchSize, kCVPixelFormatType_32BGRA, attributes, &buffer)
        cached = buffer
        return buffer
    }
}

/// Warps the face from a camera frame (420 YpCbCr full range, or BGRA for recorded frames) into
/// the normalized BGRA patch.
enum PatchRenderer {
    static func render(_ frame: CVPixelBuffer, into patch: CVPixelBuffer, normalization: FaceNormalization) -> Bool {
        if CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA {
            return renderBGRA(frame, into: patch, normalization: normalization)
        }
        guard CVPixelBufferGetPlaneCount(frame) == 2 else { return false }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(patch, [])
        defer {
            CVPixelBufferUnlockBaseAddress(patch, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(frame, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(frame, 1),
              let outBase = CVPixelBufferGetBaseAddress(patch)
        else { return false }

        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
        let out = outBase.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(frame, 0), height = CVPixelBufferGetHeightOfPlane(frame, 0)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(frame, 0), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
        let outRow = CVPixelBufferGetBytesPerRow(patch)

        // HD cameras use BT.709; fall back to BT.601 when the frame says so. Reading the
        // attachment is surprisingly slow, so it's remembered per frame size.
        let bt601 = yCbCrIsBT601(frame, width: width, height: height)
        let (rv, gu, gv, bu) = bt601 ? (1.402, 0.344136, 0.714136, 1.772) : (1.5748, 0.187324, 0.468124, 1.8556)

        @inline(__always) func lumaAt(_ x: Int, _ y: Int) -> Double {
            Double(luma[min(max(y, 0), height - 1) * lumaRow + min(max(x, 0), width - 1)])
        }

        // The patch-to-image map is projective, so its homogeneous result changes by a constant
        // step from one patch pixel to the next: one add per pixel instead of a matrix product.
        let h = normalization.patchToImage
        let step = h.columns.0
        let size = FaceNormalization.patchSize
        let halfWidth = width / 2 - 1, halfHeight = height / 2 - 1
        for py in 0..<size {
            var q = h * Vec3(0.5, Double(py) + 0.5, 1)
            var o = py * outRow
            for _ in 0..<size {
                let sx = q.x / q.z, sy = q.y / q.z
                q += step
                // Bilinear luma; chroma (half resolution) from the nearest sample is plenty.
                let fx = sx - 0.5, fy = sy - 0.5
                let x0f = fx.rounded(.down), y0f = fy.rounded(.down)
                let x0 = Int(x0f), y0 = Int(y0f)
                let ax = fx - x0f, ay = fy - y0f
                let top = lumaAt(x0, y0) * (1 - ax) + lumaAt(x0 + 1, y0) * ax
                let bottom = lumaAt(x0, y0 + 1) * (1 - ax) + lumaAt(x0 + 1, y0 + 1) * ax
                let yValue = top * (1 - ay) + bottom * ay
                let cx = min(max(Int(sx / 2), 0), halfWidth), cy = min(max(Int(sy / 2), 0), halfHeight)
                let ci = cy * chromaRow + cx * 2
                let u = Double(chroma[ci]) - 128, v = Double(chroma[ci + 1]) - 128
                out[o] = clampByte(yValue + bu * u)
                out[o + 1] = clampByte(yValue - gu * u - gv * v)
                out[o + 2] = clampByte(yValue + rv * v)
                out[o + 3] = 255
                o += 4
            }
        }
        return true
    }

    private static let matrixCache = OSAllocatedUnfairLock<(width: Int, height: Int, bt601: Bool)?>(initialState: nil)

    private static func yCbCrIsBT601(_ frame: CVPixelBuffer, width: Int, height: Int) -> Bool {
        if let cached = matrixCache.withLock({ $0 }), cached.width == width, cached.height == height {
            return cached.bt601
        }
        let matrix = CVBufferCopyAttachment(frame, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let bt601 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        matrixCache.withLock { $0 = (width, height, bt601) }
        return bt601
    }

    static func renderBGRA(_ frame: CVPixelBuffer, into patch: CVPixelBuffer, normalization: FaceNormalization) -> Bool {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(patch, [])
        defer {
            CVPixelBufferUnlockBaseAddress(patch, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        guard let inBase = CVPixelBufferGetBaseAddress(frame), let outBase = CVPixelBufferGetBaseAddress(patch) else { return false }
        let input = inBase.assumingMemoryBound(to: UInt8.self), out = outBase.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let inRow = CVPixelBufferGetBytesPerRow(frame), outRow = CVPixelBufferGetBytesPerRow(patch)
        @inline(__always) func at(_ x: Int, _ y: Int, _ c: Int) -> Double {
            Double(input[min(max(y, 0), height - 1) * inRow + min(max(x, 0), width - 1) * 4 + c])
        }
        let size = FaceNormalization.patchSize
        for py in 0..<size {
            for px in 0..<size {
                let p = normalization.imagePoint(patchX: Double(px) + 0.5, patchY: Double(py) + 0.5)
                let fx = p.x - 0.5, fy = p.y - 0.5
                let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                let ax = fx - Double(x0), ay = fy - Double(y0)
                let o = py * outRow + px * 4
                for c in 0..<3 {
                    let top = at(x0, y0, c) * (1 - ax) + at(x0 + 1, y0, c) * ax
                    let bottom = at(x0, y0 + 1, c) * (1 - ax) + at(x0 + 1, y0 + 1, c) * ax
                    out[o + c] = clampByte(top * (1 - ay) + bottom * ay)
                }
                out[o + 3] = 255
            }
        }
        return true
    }

    /// Left-right mirror of a BGRA patch.
    static func mirror(_ patch: CVPixelBuffer, into mirrored: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(patch, .readOnly)
        CVPixelBufferLockBaseAddress(mirrored, [])
        defer {
            CVPixelBufferUnlockBaseAddress(mirrored, [])
            CVPixelBufferUnlockBaseAddress(patch, .readOnly)
        }
        guard let a = CVPixelBufferGetBaseAddress(patch)?.assumingMemoryBound(to: UInt32.self),
              let b = CVPixelBufferGetBaseAddress(mirrored)?.assumingMemoryBound(to: UInt32.self)
        else { return }
        let size = FaceNormalization.patchSize
        let rowA = CVPixelBufferGetBytesPerRow(patch) / 4, rowB = CVPixelBufferGetBytesPerRow(mirrored) / 4
        for y in 0..<size {
            for x in 0..<size {
                b[y * rowB + x] = a[y * rowA + size - 1 - x]
            }
        }
    }

    @inline(__always) private static func clampByte(_ v: Double) -> UInt8 {
        UInt8(min(max(v.rounded(), 0), 255))
    }
}
