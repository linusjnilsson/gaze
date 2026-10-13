import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import os
import Vision

/// Turns camera frames into `FaceSample`s using Vision for face/landmark detection and a
/// dark-pixel centroid search for the iris (Vision's pupil landmark alone is too coarse).
///
/// Not thread-safe; call from a single serial queue.
public final class FaceAnalyzer: @unchecked Sendable {
    private let headPose = HeadPoseEstimator()
    private let geometryLock = OSAllocatedUnfairLock(initialState: (fieldOfView: GazeModel.defaultFieldOfView, face: FaceShape.generic, source: GazeSource.iris, correction: FeatureCorrection?.none, mirrored: true))
    private let recordingLock = OSAllocatedUnfairLock(initialState: false)
    /// Loaded on first use, on the analysis queue.
    private lazy var network = GazeNetwork.load()
    private lazy var imageContext = CIContext()
    /// Reused across frames: Vision resolves its detectors' configuration (model paths, compute
    /// devices) per handler and request, which costs more CPU than it should 30 times a second.
    private let sequenceHandler = VNSequenceRequestHandler()
    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()
    private let landmarksRequest: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        return request
    }()

    /// The camera's horizontal field of view in degrees, the user's face, where eye angles come
    /// from, the user's correction of the network, and whether the network also looks at the
    /// mirrored face. Safe to set from any thread.
    public var geometry: (fieldOfView: Double, face: FaceShape, source: GazeSource, correction: FeatureCorrection?, mirrored: Bool) {
        get { geometryLock.withLock { $0 } }
        set { geometryLock.withLock { $0 = newValue } }
    }

    /// Whether samples carry a JPEG of the face, for recording calibration data. Safe to set from any thread.
    public var capturesFaceImages: Bool {
        get { recordingLock.withLock { $0 } }
        set { recordingLock.withLock { $0 = newValue } }
    }

    /// The last face found, so tracking can continue for a moment when the face detector gives up
    /// (it struggles with faces cut off by the frame) while the landmarks are still findable.
    private var lastFace: (box: CGRect, edge: TrackingIssue.Edge?, time: TimeInterval)?
    static let trackingGrace: TimeInterval = 1.0

    public init() {}

    public func analyze(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> FrameAnalysis {
        try? sequenceHandler.perform([faceRequest], on: pixelBuffer, orientation: .up)

        // Track the largest (closest) face only.
        var face = faceRequest.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area })
        let detected = face != nil
        if face == nil, let lastFace, timestamp - lastFace.time < Self.trackingGrace {
            face = VNFaceObservation(
                requestRevision: VNDetectFaceRectanglesRequestRevision3,
                boundingBox: lastFace.box,
                roll: nil,
                yaw: nil,
                pitch: nil
            )
        }
        guard let face else { return lost(at: timestamp) }

        landmarksRequest.inputFaceObservations = [face]
        try? sequenceHandler.perform([landmarksRequest], on: pixelBuffer, orientation: .up)
        guard let landmarks = landmarksRequest.results?.first?.landmarks,
              // Without the detector's confirmation, only trust confident landmarks.
              detected || landmarks.confidence >= 0.5,
              let eyeRegionA = landmarks.leftEye,
              let eyeRegionB = landmarks.rightEye
        else { return lost(at: timestamp) }

        // When following without the detector, re-center the box on the landmarks for the next frame.
        let box = detected ? face.boundingBox : Self.box(around: landmarks, in: face.boundingBox) ?? face.boundingBox
        let clipped = Self.clippedEdges(of: box, margin: 0.01)
        lastFace = (box, Self.clippedEdges(of: box, margin: 0.03).first, timestamp)

        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        func visible(_ p: CGPoint) -> Bool {
            Self.isVisible(p, imageSize: imageSize, faceBox: box, clippedEdges: clipped)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let luma = LumaPlane(pixelBuffer)

        let partialIssue = TrackingIssue.partlyOutOfView(clipped.first ?? .bottom)
        guard let eyeA = measureEye(
            contour: eyeRegionA.pointsInImage(imageSize: imageSize),
            pupil: landmarks.leftPupil?.pointsInImage(imageSize: imageSize).first,
            luma: luma,
            imageSize: imageSize
        ), let eyeB = measureEye(
            contour: eyeRegionB.pointsInImage(imageSize: imageSize),
            pupil: landmarks.rightPupil?.pointsInImage(imageSize: imageSize).first,
            luma: luma,
            imageSize: imageSize
        ) else { return FrameAnalysis(sample: nil, issue: clipped.isEmpty ? .noFace : partialIssue) }
        // Sort by image position rather than trusting Vision's left/right naming.
        let (imageLeft, imageRight) = eyeA.center.x < eyeB.center.x ? (eyeA, eyeB) : (eyeB, eyeA)

        let corners = [imageLeft.leftCorner, imageLeft.rightCorner, imageRight.leftCorner, imageRight.rightCorner]
        guard corners.allSatisfy({ visible(CGPoint(x: $0.x, y: $0.y)) }) else {
            return FrameAnalysis(sample: nil, issue: partialIssue)
        }

        // Nose and mouth help pin down head pose, but tracking carries on without them.
        func usable(_ p: CGPoint?) -> SIMD2<Double>? {
            p.flatMap { visible($0) ? SIMD2($0.x, $0.y) : nil }
        }
        let crest = landmarks.noseCrest?.pointsInImage(imageSize: imageSize) ?? []
        let lips = landmarks.outerLips?.pointsInImage(imageSize: imageSize) ?? []
        var measurements = FaceMeasurements(
            timestamp: timestamp,
            imageSize: SIMD2(imageSize.width, imageSize.height),
            landmarks: corners.map(Optional.some) + [
                // The crest runs from the bridge to the tip, so the tip is its lower end. (Its
                // lowest point overall can switch between neighbors as the head turns.)
                usable([crest.first, crest.last].compactMap { $0 }.min(by: { $0.y < $1.y })),
                usable(lips.min(by: { $0.x < $1.x })),
                usable(lips.max(by: { $0.x < $1.x })),
            ],
            irisImageLeft: imageLeft.irisPixel,
            irisImageRight: imageRight.irisPixel
        )
        let partial = measurements.landmarks.contains { $0 == nil }
        let geometry = geometry
        guard let (head, irisGaze) = measurements.observe(fieldOfView: geometry.fieldOfView, face: geometry.face, using: headPose) else {
            return FrameAnalysis(sample: nil, issue: partial || !clipped.isEmpty ? partialIssue : .noFace)
        }
        // Always run when available, so calibration can compare both sources.
        if let network {
            network.averagesMirrored = geometry.mirrored
            let intrinsics = CameraIntrinsics(imageWidth: imageSize.width, imageHeight: imageSize.height, horizontalFOVDegrees: geometry.fieldOfView)
            if let estimate = network.estimate(in: pixelBuffer, head: head, face: geometry.face, intrinsics: intrinsics) {
                measurements.networkGaze = estimate.direction
                measurements.networkReading = estimate.features.map {
                    NetworkReading(angles: estimate.angles, features: $0, normalization: estimate.normalization)
                }
            }
        }
        var gaze = irisGaze
        if geometry.source == .network {
            guard let direction = measurements.networkDirection(correction: geometry.correction) else { return FrameAnalysis(sample: nil, issue: .noFace) }
            gaze = irisGaze.withGaze(direction)
        }

        return FrameAnalysis(
            sample: FaceSample(
                timestamp: timestamp,
                faceBox: box,
                rightEye: imageLeft.sample,
                leftEye: imageRight.sample,
                measurements: measurements,
                head: head,
                observation: gaze,
                image: capturesFaceImages ? faceImage(pixelBuffer, box: box, imageSize: imageSize) : nil
            ),
            issue: partial ? partialIssue : nil
        )
    }

    /// The face and some surroundings as a JPEG, so recorded frames can be re-analyzed offline.
    private func faceImage(_ pixelBuffer: CVPixelBuffer, box: CGRect, imageSize: CGSize) -> FaceImage? {
        let pixels = CGRect(x: box.minX * imageSize.width, y: box.minY * imageSize.height, width: box.width * imageSize.width, height: box.height * imageSize.height)
        let crop = pixels.insetBy(dx: -pixels.width * 0.3, dy: -pixels.height * 0.3)
            .intersection(CGRect(origin: .zero, size: imageSize))
            .integral
        guard !crop.isEmpty, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // Core Image, like Vision, puts the origin at the bottom left.
        let image = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: crop)
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9]
        return imageContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
            .map { FaceImage(jpeg: $0, rect: crop) }
    }

    /// No usable face this frame. If the face was last seen at the edge of the frame, say so.
    private func lost(at timestamp: TimeInterval) -> FrameAnalysis {
        if let lastFace, timestamp - lastFace.time < 3, let edge = lastFace.edge {
            return FrameAnalysis(sample: nil, issue: .partlyOutOfView(edge))
        }
        return FrameAnalysis(sample: nil, issue: .noFace)
    }

    /// Image edges (normalized box, lower-left origin) that a face box touches or crosses, most likely first.
    static func clippedEdges(of box: CGRect, margin: CGFloat) -> [TrackingIssue.Edge] {
        var edges: [TrackingIssue.Edge] = []
        // The camera sits above the screen, so leaning in pushes the face off the bottom first.
        if box.minY < margin { edges.append(.bottom) }
        if box.maxY > 1 - margin { edges.append(.top) }
        if box.minX < margin { edges.append(.left) }
        if box.maxX > 1 - margin { edges.append(.right) }
        return edges
    }

    /// Whether a landmark (pixels, lower-left origin) is genuinely in view. Points at the image edge,
    /// or in the part of a face that the frame cuts off, are Vision's extrapolations, not measurements.
    static func isVisible(_ p: CGPoint, imageSize: CGSize, faceBox box: CGRect, clippedEdges: [TrackingIssue.Edge]) -> Bool {
        let n = CGPoint(x: p.x / imageSize.width, y: p.y / imageSize.height)
        let margin = 0.015
        guard n.x > margin, n.x < 1 - margin, n.y > margin, n.y < 1 - margin else { return false }
        let relative = CGPoint(x: (n.x - box.minX) / box.width, y: (n.y - box.minY) / box.height)
        for edge in clippedEdges {
            switch edge {
            case .bottom where relative.y < 0.35, .top where relative.y > 0.65,
                 .left where relative.x < 0.35, .right where relative.x > 0.65:
                return false
            default:
                continue
            }
        }
        return true
    }

    /// A face-sized box around the landmarks (normalized image coordinates).
    private static func box(around landmarks: VNFaceLandmarks2D, in faceBox: CGRect) -> CGRect? {
        guard let points = landmarks.allPoints?.normalizedPoints, !points.isEmpty else { return nil }
        // Landmark points are normalized to the face box they were found in.
        let xs = points.map { faceBox.minX + $0.x * faceBox.width }
        let ys = points.map { faceBox.minY + $0.y * faceBox.height }
        let tight = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return tight.insetBy(dx: -tight.width * 0.1, dy: -tight.height * 0.1)
    }

    private struct EyeMeasurement {
        var sample: EyeSample
        /// Pixel positions, lower-left origin.
        var leftCorner: SIMD2<Double>
        var rightCorner: SIMD2<Double>
        var irisPixel: SIMD2<Double>
        var center: SIMD2<Double> { (leftCorner + rightCorner) / 2 }
    }

    private func measureEye(contour: [CGPoint], pupil: CGPoint?, luma: LumaPlane?, imageSize: CGSize) -> EyeMeasurement? {
        guard contour.count >= 4,
              let cornerA = contour.min(by: { $0.x < $1.x }),
              let cornerB = contour.max(by: { $0.x < $1.x })
        else { return nil }

        let axis = CGPoint(x: cornerB.x - cornerA.x, y: cornerB.y - cornerA.y)
        let lengthSquared = axis.x * axis.x + axis.y * axis.y
        guard lengthSquared > 4 else { return nil }

        func toUV(_ p: CGPoint) -> CGPoint {
            let d = CGPoint(x: p.x - cornerA.x, y: p.y - cornerA.y)
            return CGPoint(
                x: (d.x * axis.x + d.y * axis.y) / lengthSquared,
                y: (axis.x * d.y - axis.y * d.x) / lengthSquared
            )
        }

        let contourUV = contour.map(toUV)
        let vs = contourUV.map(\.y)
        let openness = Double((vs.max() ?? 0) - (vs.min() ?? 0))

        var iris: CGPoint
        var refined = false
        if openness >= FaceSample.blinkOpennessThreshold, let luma, let found = Self.locateIris(in: contour, luma: luma) {
            iris = found
            refined = true
        } else if let pupil {
            iris = pupil
        } else {
            let n = CGFloat(contour.count)
            iris = CGPoint(x: contour.reduce(0) { $0 + $1.x } / n, y: contour.reduce(0) { $0 + $1.y } / n)
        }

        func normalized(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x / imageSize.width, y: p.y / imageSize.height)
        }

        return EyeMeasurement(
            sample: EyeSample(
                contour: contour.map(normalized),
                contourUV: contourUV,
                iris: normalized(iris),
                irisUV: toUV(iris),
                openness: openness,
                irisRefined: refined
            ),
            leftCorner: SIMD2(cornerA.x, cornerA.y),
            rightCorner: SIMD2(cornerB.x, cornerB.y),
            irisPixel: SIMD2(iris.x, iris.y)
        )
    }

    /// Finds the iris as the weighted centroid of the darkest pixels inside the eye contour.
    /// `contour` is in pixel coordinates with a lower-left origin.
    static func locateIris(in contour: [CGPoint], luma: LumaPlane) -> CGPoint? {
        let xs = contour.map(\.x), ys = contour.map(\.y)
        let minX = max(0, Int(xs.min()!.rounded(.down)))
        let maxX = min(luma.width - 1, Int(xs.max()!.rounded(.up)))
        let minY = max(0, Int(ys.min()!.rounded(.down)))
        let maxY = min(luma.height - 1, Int(ys.max()!.rounded(.up)))
        guard maxX - minX >= 6, maxY - minY >= 2 else { return nil }

        var inside: [(x: Int, y: Int, value: UInt8)] = []
        inside.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        var histogram = [Int](repeating: 0, count: 256)
        for y in minY...maxY {
            for x in minX...maxX where pointInPolygon(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), contour) {
                let v = luma.value(x: x, y: y)
                inside.append((x, y, v))
                histogram[Int(v)] += 1
            }
        }
        guard inside.count >= 12 else { return nil }

        // The iris and pupil are the darkest part of the visible eye. Take roughly the darkest 22%.
        let cutoffCount = max(4, inside.count * 22 / 100)
        var cumulative = 0
        var threshold = 0
        for (value, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= cutoffCount {
                threshold = value
                break
            }
        }

        var sumX = 0.0, sumY = 0.0, sumW = 0.0
        for p in inside where Int(p.value) <= threshold {
            let w = Double(threshold - Int(p.value) + 1)
            sumX += (Double(p.x) + 0.5) * w
            sumY += (Double(p.y) + 0.5) * w
            sumW += w
        }
        guard sumW > 0 else { return nil }
        return CGPoint(x: sumX / sumW, y: sumY / sumW)
    }

    static func pointInPolygon(_ p: CGPoint, _ polygon: [CGPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

/// Read access to the luminance plane of a locked camera buffer, addressed with a lower-left origin
/// to match Vision's coordinate space.
struct LumaPlane {
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    init?(_ buffer: CVPixelBuffer) {
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let address = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        // Only the luma plane of YpCbCr buffers is meaningful as grayscale.
        guard planar else { return nil }
        base = UnsafePointer(address.assumingMemoryBound(to: UInt8.self))
        width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    }

    func value(x: Int, y: Int) -> UInt8 {
        base[(height - 1 - y) * bytesPerRow + x]
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
