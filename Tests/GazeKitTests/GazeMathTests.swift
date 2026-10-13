import CoreGraphics
import CoreVideo
import Foundation
@testable import GazeKit
import simd
import Testing

/// Renders what the camera would see for a known head pose, eye correction, and gaze target.
struct SyntheticScene {
    var fieldOfView = GazeModel.defaultFieldOfView
    var imageSize = SIMD2<Double>(1920, 1080)
    /// The user's true eye correction, which calibration should recover.
    var eye: [Double] = [0.03, 1, 0, -0.02, 1, 0]
    /// Extra error in the measured eye angles that no affine correction can express, e.g. iris
    /// detection that's biased differently toward each corner.
    var distortion: @Sendable (SIMD2<Double>) -> SIMD2<Double> = { _ in .zero }
    /// The user's actual face, which real users never match exactly: landmarks in
    /// `FaceShape.generic.landmarks` order, and the two eyeball centers.
    var face = FaceShape.generic.landmarks
    var eyeballs = (left: FaceShape.generic.eyeballCenterImageLeft, right: FaceShape.generic.eyeballCenterImageRight)
    /// Detection noise (standard deviation, pixels) on the landmarks and on the irises.
    var landmarkNoise = 0.0
    var irisNoise = 0.0
    /// When set, frames carry a gaze network estimate: the true gaze direction off by this much
    /// noise (standard deviation, radians, per axis).
    var networkNoise: Double?
    /// When set (with `networkNoise`), frames also carry what the network saw: these features of
    /// the true normalized gaze angles, and estimates off by `networkPersonalError` of them, the
    /// way a generic network is off for one person.
    var networkFeatures: (@Sendable (SIMD2<Double>) -> [Float])?
    var networkPersonalError: @Sendable (SIMD2<Double>) -> SIMD2<Double> = { _ in .zero }

    /// A face with different proportions than the generic model: smaller, eyes closer together,
    /// a more prominent nose, a lower mouth. With Vision-like detection noise.
    static var realistic: SyntheticScene {
        var scene = SyntheticScene()
        let corners = [Vec3(-44, 37, 33), Vec3(-15, 36, 26), Vec3(15, 36, 26), Vec3(44, 37, 33)]
        scene.face = (corners + [Vec3(0, 0, 0), Vec3(-23, -34, 25), Vec3(23, -34, 25)]).map { $0 * 0.95 }
        scene.eyeballs = (Vec3(-29.5, 36.5, 36) * 0.95, Vec3(29.5, 36.5, 36) * 0.95)
        scene.landmarkNoise = 1.5
        scene.irisNoise = 0.4
        // The real camera is a bit wider than the assumed one.
        scene.fieldOfView = 76
        return scene
    }

    var intrinsics: CameraIntrinsics {
        CameraIntrinsics(imageWidth: imageSize.x, imageHeight: imageSize.y, horizontalFOVDegrees: fieldOfView)
    }

    func measurements(head: HeadPose, lookingAt target: Vec3, time: TimeInterval) -> FaceMeasurements {
        var rng = SeededGenerator(seed: UInt64(bitPattern: Int64(time * 1000)) &+ 17)
        return measurements(head: head, lookingAt: target, time: time, using: &rng)
    }

    func measurements(head: HeadPose, lookingAt target: Vec3, time: TimeInterval, using rng: inout SeededGenerator) -> FaceMeasurements {
        func noise(_ sigma: Double) -> SIMD2<Double> {
            guard sigma > 0 else { return .zero }
            // Box–Muller.
            let u = Double.random(in: 1e-12..<1, using: &rng), v = Double.random(in: 0..<1, using: &rng)
            let r = sigma * (-2 * log(u)).squareRoot()
            return SIMD2(r * cos(2 * .pi * v), r * sin(2 * .pi * v))
        }
        func iris(_ eyeballCenter: Vec3) -> SIMD2<Double> {
            let c = head.toCamera(eyeballCenter)
            let visual = EyeModel.angles(ofHeadDirection: head.rotation.transpose * simd_normalize(target - c))
            // Invert the eye correction (no cross terms here) to get the iris direction.
            let raw = SIMD2((visual.x - eye[0]) / eye[1], (visual.y - eye[3]) / eye[4]) + distortion(visual)
            let optical = head.rotation * EyeModel.direction(fromAngles: raw)
            return intrinsics.project(c + optical * EyeModel.irisRadius) + noise(irisNoise)
        }
        let network = networkNoise.map { sigma -> Vec3 in
            let origin = head.toCamera((eyeballs.left + eyeballs.right) / 2)
            let n = noise(sigma)
            let truth = simd_normalize(target - origin)
            return simd_normalize(truth + Vec3(n.x, n.y, 0))
        }
        var measurements = FaceMeasurements(
            timestamp: time,
            imageSize: imageSize,
            landmarks: face.map { intrinsics.project(head.toCamera($0)) + noise(landmarkNoise) },
            irisImageLeft: iris(eyeballs.left),
            irisImageRight: iris(eyeballs.right),
            networkGaze: network
        )
        if let networkFeatures, let sigma = networkNoise,
           let normalization = FaceNormalization(head: head, face: FaceShape(landmarks: face), intrinsics: intrinsics, imageHeight: imageSize.y) {
            let truth = normalization.angles(of: target - normalization.center)
            let angles = truth + networkPersonalError(truth) + noise(sigma)
            measurements.networkReading = NetworkReading(angles: angles, features: networkFeatures(truth), normalization: normalization)
            measurements.networkGaze = normalization.gazeDirection(pitch: angles.x, yaw: angles.y)
        }
        return measurements
    }

    /// A head roughly 55 cm in front of the camera, facing the screen below it.
    static func head(offset: Vec3 = .zero, rotation: Vec3 = .zero) -> HeadPose {
        HeadPose(
            rotation: Rotation.matrix(Vec3(-0.15, 0, 0) + rotation),
            translation: Vec3(0, -120, 550) + offset
        )
    }
}

struct HeadPoseTests {
    @Test(arguments: [
        (Vec3.zero, Vec3.zero),
        (Vec3(60, -40, 80), Vec3(0.1, 0.2, 0.05)),
        (Vec3(-80, 30, -100), Vec3(-0.15, -0.25, -0.1)),
    ])
    func recoversPose(offset: Vec3, rotation: Vec3) throws {
        let scene = SyntheticScene()
        let truth = SyntheticScene.head(offset: offset, rotation: rotation)
        let points = FaceShape.generic.landmarks.map { scene.intrinsics.project(truth.toCamera($0)) }
        let pose = try #require(HeadPoseEstimator().estimate(points, intrinsics: scene.intrinsics, time: 0))
        #expect(simd_length(pose.translation - truth.translation) < 1)
        let angle = simd_length(Rotation.headAngles(pose.rotation) - Rotation.headAngles(truth.rotation))
        #expect(angle < 0.005)
    }
}

extension HeadPoseTests {
    /// Vision occasionally misplaces the nose by tens of pixels for a frame; the pose shouldn't jump.
    @Test func ignoresAMisplacedNose() throws {
        let scene = SyntheticScene()
        let truth = SyntheticScene.head(rotation: Vec3(0.05, 0.2, 0))
        var points: [SIMD2<Double>?] = FaceShape.generic.landmarks.map { scene.intrinsics.project(truth.toCamera($0)) }
        points[4]! += SIMD2(35, -10)
        let pose = try #require(HeadPoseEstimator().estimate(points, intrinsics: scene.intrinsics, time: 0))
        #expect(simd_length(Rotation.headAngles(pose.rotation) - Rotation.headAngles(truth.rotation)) < 0.01)
        #expect(simd_length(pose.translation - truth.translation) < 3)
    }
}

struct PartialFaceTests {
    let scene = SyntheticScene()

    func projected(_ pose: HeadPose) -> [SIMD2<Double>?] {
        FaceShape.generic.landmarks.map { scene.intrinsics.project(pose.toCamera($0)) }
    }

    @Test func tracksWithMouthOutOfView() throws {
        let estimator = HeadPoseEstimator()
        let start = SyntheticScene.head(offset: Vec3(0, 0, -250))
        _ = try #require(estimator.estimate(projected(start), intrinsics: scene.intrinsics, time: 0))

        // Leaning in further and turning slightly; the mouth has left the frame.
        let truth = SyntheticScene.head(offset: Vec3(10, 5, -300), rotation: Vec3(0.03, 0.05, 0))
        var points = projected(truth)
        points[5] = nil
        points[6] = nil
        let pose = try #require(estimator.estimate(points, intrinsics: scene.intrinsics, time: 1.0 / 30))
        #expect(simd_length(pose.translation - truth.translation) < 3)
        #expect(simd_length(Rotation.headAngles(pose.rotation) - Rotation.headAngles(truth.rotation)) < 0.02)
    }

    @Test func startsFromEyesAndNose() throws {
        let truth = SyntheticScene.head(offset: Vec3(0, 0, -280))
        var points = projected(truth)
        points[5] = nil
        points[6] = nil
        let pose = try #require(HeadPoseEstimator().estimate(points, intrinsics: scene.intrinsics, time: 0))
        #expect(simd_length(pose.translation - truth.translation) < 3)
    }

    @Test func keepsTrackingFromEyesAloneBriefly() throws {
        let estimator = HeadPoseEstimator()
        let start = SyntheticScene.head(offset: Vec3(0, 0, -300))
        _ = try #require(estimator.estimate(projected(start), intrinsics: scene.intrinsics, time: 0))
        let truth = SyntheticScene.head(offset: Vec3(5, 0, -305), rotation: Vec3(0, 0.01, 0))
        var points = projected(truth)
        points[4] = nil
        points[5] = nil
        points[6] = nil
        let pose = try #require(estimator.estimate(points, intrinsics: scene.intrinsics, time: 1.0 / 30))
        #expect(simd_length(pose.translation - truth.translation) < 5)
    }

    @Test func refusesEyesAloneFromAStandingStart() {
        var points = projected(SyntheticScene.head())
        points[4] = nil
        points[5] = nil
        points[6] = nil
        #expect(HeadPoseEstimator().estimate(points, intrinsics: scene.intrinsics, time: 0) == nil)
    }

    @Test func dropsLandmarksWhereTheFrameCutsTheFaceOff() {
        let size = CGSize(width: 1920, height: 1080)
        // A face box running off the bottom of the image.
        let box = CGRect(x: 0.3, y: -0.1, width: 0.4, height: 0.8)
        let edges = FaceAnalyzer.clippedEdges(of: box, margin: 0.01)
        #expect(edges == [.bottom])
        func visible(_ fx: Double, _ fy: Double) -> Bool {
            FaceAnalyzer.isVisible(CGPoint(x: fx * size.width, y: fy * size.height), imageSize: size, faceBox: box, clippedEdges: edges)
        }
        #expect(visible(0.4, 0.5), "eyes, high in the face box")
        #expect(visible(0.5, 0.3), "nose, mid-face")
        #expect(!visible(0.45, 0.1), "mouth, in the cut-off lower part")
        #expect(!visible(0.5, 0.005), "anything at the image edge")
    }
}

struct EyeModelTests {
    @Test func recoversOpticalAxis() {
        let scene = SyntheticScene()
        let center = Vec3(20, -80, 560)
        let axis = simd_normalize(Vec3(0.2, -0.1, -1))
        let pixel = scene.intrinsics.project(center + axis * EyeModel.irisRadius)
        let recovered = EyeModel.opticalAxis(eyeCenter: center, irisPixel: pixel, intrinsics: scene.intrinsics)
        #expect(simd_length(recovered - axis) < 1e-6)
    }

    @Test func anglesRoundTrip() {
        let a = SIMD2(0.2, -0.1)
        #expect(simd_length(EyeModel.angles(ofHeadDirection: EyeModel.direction(fromAngles: a)) - a) < 1e-12)
    }
}

struct GazeModelTests {
    let laptop = DisplayInfo(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1470, height: 956), millimetersPerPoint: 0.2, vendor: 1, model: 1, serial: 1, name: "Built-in", isBuiltin: true)
    let monitor = DisplayInfo(displayID: 2, frame: CGRect(x: -200, y: 956, width: 2560, height: 1440), millimetersPerPoint: 0.233, vendor: 2, model: 2, serial: 2, name: "External")

    /// Grid targets on each display, with the head moving between frames as in a real calibration.
    func samples(scene: SyntheticScene, planes: [DisplayPlane], seed: UInt64, framesPerTarget: Int = 4) -> [CalibrationSample] {
        var rng = SeededGenerator(seed: seed)
        var result: [CalibrationSample] = []
        var time = 0.0
        for (displayIndex, plane) in planes.enumerated() {
            for fx in [0.06, 0.5, 0.94] {
                for fy in [0.06, 0.5, 0.94] {
                    let target = plane.point(fromLocal: SIMD2(fx, fy) * plane.size)
                    let target3D = plane.origin + plane.xAxis * (fx * plane.size.x) + plane.yAxis * (fy * plane.size.y)
                    let targetIndex = result.last.map { $0.targetIndex + 1 } ?? 0
                    for _ in 0..<framesPerTarget {
                        let head = SyntheticScene.head(
                            offset: Vec3(.random(in: -50...50, using: &rng), .random(in: -30...30, using: &rng), .random(in: -60...60, using: &rng)),
                            rotation: Vec3(.random(in: -0.1...0.1, using: &rng), .random(in: -0.15...0.15, using: &rng), 0)
                        )
                        result.append(CalibrationSample(
                            measurements: scene.measurements(head: head, lookingAt: target3D, time: time),
                            target: target,
                            targetIndex: targetIndex,
                            displayIndex: displayIndex
                        ))
                        time += 1
                    }
                }
            }
        }
        return result
    }

    /// Mean on-screen error in millimeters for fresh head poses the fit never saw.
    func heldOutError(model: GazeModel, scene: SyntheticScene, planes: [DisplayPlane]) -> Double {
        var errors: [Double] = []
        for (plane, truth) in zip(model.planes, planes) {
            for (fx, fy) in [(0.3, 0.3), (0.7, 0.6), (0.5, 0.8)] {
                for offset in [Vec3(70, 0, 0), Vec3(-60, 40, -80), Vec3(0, -40, 90)] {
                    let target3D = truth.origin + truth.xAxis * (fx * truth.size.x) + truth.yAxis * (fy * truth.size.y)
                    let m = scene.measurements(head: SyntheticScene.head(offset: offset, rotation: Vec3(0, 0.1, 0)), lookingAt: target3D, time: 0)
                    guard let (_, observation) = m.observe(for: model, using: HeadPoseEstimator()),
                          let predicted = model.predict(observation) else {
                        errors.append(.infinity)
                        continue
                    }
                    let error = plane.local(from: predicted) - SIMD2(fx, fy) * plane.size
                    errors.append(simd_length(error))
                }
            }
        }
        return errors.reduce(0, +) / Double(errors.count)
    }

    @Test func calibratesBuiltInDisplayAndHandlesHeadMotion() throws {
        let scene = SyntheticScene()
        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let model = try #require(GazeModel.fit(samples(scene: scene, planes: planes, seed: 1), displays: [laptop]))
        #expect(heldOutError(model: model, scene: scene, planes: planes) < 6)
    }

    /// Spread of predictions (mm, 90th percentile distance from the target) while the eyes stay
    /// on one spot and the head moves and turns, averaged over many noisy frames per pose.
    func headMotionSpread(model: GazeModel, scene: SyntheticScene, plane: DisplayPlane) -> (bias: Double, spread: Double) {
        var rng = SeededGenerator(seed: 99)
        let target = SIMD2(0.5, 0.45) * plane.size
        let target3D = plane.origin + plane.xAxis * target.x + plane.yAxis * target.y
        var errors: [Double] = []
        var time = 1000.0
        for offset in [Vec3.zero, Vec3(80, 0, 0), Vec3(-80, 0, 0), Vec3(0, 50, 0), Vec3(0, -40, 0), Vec3(0, 0, 120), Vec3(0, 0, -120)] {
            for rotation in [Vec3.zero, Vec3(0, 0.2, 0), Vec3(0, -0.2, 0), Vec3(0.12, 0, 0), Vec3(-0.12, 0, 0)] {
                let head = SyntheticScene.head(offset: offset, rotation: rotation)
                let estimator = HeadPoseEstimator()
                var hits: [SIMD2<Double>] = []
                for _ in 0..<15 {
                    let m = scene.measurements(head: head, lookingAt: target3D, time: time, using: &rng)
                    time += 1.0 / 30
                    guard let (_, o) = m.observe(for: model, using: estimator),
                          let hit = model.hit(on: model.planes[0], for: o) else { continue }
                    hits.append(hit)
                }
                guard !hits.isEmpty else { errors.append(.infinity); continue }
                let mean = hits.reduce(.zero, +) / Double(hits.count)
                errors.append(simd_length(mean - target))
            }
        }
        errors.sort()
        return (median(errors), errors[errors.count * 9 / 10])
    }

    /// Real faces don't match the generic face model, real detections are noisy, and the camera's
    /// field of view isn't exactly the assumed one. The gaze point must still stay put when only
    /// the head moves.
    @Test func keepsGazeSteadyWhileHeadMovesWithRealisticFace() throws {
        let scene = SyntheticScene.realistic
        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let model = try #require(GazeModel.fit(samples(scene: scene, planes: planes, seed: 11, framesPerTarget: 15), displays: [laptop]))
        let (bias, spread) = headMotionSpread(model: model, scene: scene, plane: planes[0])
        #expect(model.face != nil && model.face != .generic)
        #expect(bias < 10, "median \(bias) mm")
        #expect(spread < 20, "90th percentile \(spread) mm")
    }

    /// Calibrating on the gaze network's estimates works through the same model, and its errors
    /// don't depend on the iris or the eyeball lever.
    @Test func calibratesWithTheGazeNetwork() throws {
        var scene = SyntheticScene.realistic
        scene.irisNoise = 3 // Useless irises: only the network can do well.
        scene.networkNoise = 0.02
        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let samples = samples(scene: scene, planes: planes, seed: 5, framesPerTarget: 10)
        let network = try #require(GazeModel.fit(samples, displays: [laptop], source: .network))
        let iris = try #require(GazeModel.fit(samples, displays: [laptop], source: .iris))
        #expect(network.gazeSource == .network)
        let networkError = heldOutError(model: network, scene: scene, planes: planes)
        #expect(networkError < 25, "\(networkError) mm")
        #expect(networkError < heldOutError(model: iris, scene: scene, planes: planes))
    }

    /// A generic network that's off for this person in a way that varies across the screen, more
    /// than a calibration's handful of dots can pin down. Everyday clicks carrying the network's
    /// features relearn the personalization, and the learner adopts it.
    @Test func personalizesTheNetworkFromClicks() throws {
        var scene = SyntheticScene.realistic
        scene.irisNoise = 3
        scene.networkNoise = 0.01
        var rng = SeededGenerator(seed: 31)
        let mixing = (0..<48).map { _ in (Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng)) }
        scene.networkFeatures = { g in
            mixing.map { m in tanh(m.0 * Float(g.x) * 6 + m.1 * Float(g.y) * 6 + m.2) }
        }
        scene.networkPersonalError = { g in SIMD2(0.02 + 0.3 * g.x + 2 * g.y * g.y, -0.03 - 0.25 * g.y + 3 * g.x * g.y) }

        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let plane = planes[0]
        let calibration = samples(scene: scene, planes: planes, seed: 32, framesPerTarget: 6)
        let calibrated = try #require(GazeModel.fit(calibration, displays: [laptop], source: .network))
        let estimator = HeadPoseEstimator()
        var learning = Dictionary(grouping: calibration, by: \.targetIndex).values.flatMap { frames in
            InteractionSample.event(
                frames.compactMap { f in f.measurements.observe(for: calibrated, using: estimator).map { ($0.observation, f.measurements.networkReading) } },
                target: frames[0].target, displayID: laptop.displayID, source: .calibration, date: Date(timeIntervalSince1970: 1_000_000)
            )
        }
        for i in 0..<160 {
            let spot = SIMD2(Double.random(in: 0.05...0.95, using: &rng), .random(in: 0.05...0.95, using: &rng)) * plane.size
            let offset = Vec3(.random(in: -50...50, using: &rng), .random(in: -30...30, using: &rng), .random(in: -60...60, using: &rng))
            let frames = (0..<4).compactMap { f -> (GazeObservation, NetworkReading?)? in
                let m = scene.measurements(
                    head: SyntheticScene.head(offset: offset, rotation: Vec3(0, .random(in: -0.15...0.15, using: &rng), 0)),
                    lookingAt: plane.origin + plane.xAxis * spot.x + plane.yAxis * spot.y,
                    time: 5000 + Double(i) * 10 + Double(f) / 30,
                    using: &rng
                )
                return m.observe(for: calibrated, using: estimator).map { ($0.observation, m.networkReading) }
            }
            learning += InteractionSample.event(frames, target: plane.point(fromLocal: spot), displayID: laptop.displayID, source: .click, date: Date(timeIntervalSince1970: 1_000_100 + Double(i) * 60))
        }

        // Saved and loaded, as profiles are.
        let reloaded = try JSONDecoder().decode([InteractionSample].self, from: JSONEncoder().encode(learning))
        #expect(reloaded.map(\.features) == learning.map(\.features))
        #expect(zip(reloaded, learning).allSatisfy { a, b in
            a.network.map { simd_length($0.angles) } == b.network.map { simd_length($0.angles) }
                && a.network?.normalization.gazeDirection(pitch: 0.1, yaw: 0.2) == b.network?.normalization.gazeDirection(pitch: 0.1, yaw: 0.2)
        })

        let now = learning.map(\.date).max()!
        let outcome = try #require(LearningFit.refit(base: calibrated, current: calibrated, samples: reloaded, now: now, recencyHalfLife: 7 * 86400))
        #expect(outcome.personalized)
        #expect(outcome.model.networkMirrored == calibrated.networkMirrored)
        // Judged like everyday use: fresh spots anywhere on screen, from varied head poses.
        func error(_ model: GazeModel) -> Double {
            var rng = SeededGenerator(seed: 33)
            var errors: [Double] = []
            for i in 0..<60 {
                let spot = SIMD2(Double.random(in: 0.05...0.95, using: &rng), .random(in: 0.05...0.95, using: &rng)) * plane.size
                let head = SyntheticScene.head(
                    offset: Vec3(.random(in: -50...50, using: &rng), .random(in: -30...30, using: &rng), .random(in: -60...60, using: &rng)),
                    rotation: Vec3(0, .random(in: -0.15...0.15, using: &rng), 0)
                )
                let m = scene.measurements(head: head, lookingAt: plane.origin + plane.xAxis * spot.x + plane.yAxis * spot.y, time: 90000 + Double(i), using: &rng)
                guard let (_, o) = m.observe(for: model, using: HeadPoseEstimator()), let hit = model.hit(on: plane, for: o) else { continue }
                errors.append(simd_length(hit - spot))
            }
            return median(errors)
        }
        let plain = try #require(GazeModel.adapt(calibrated, to: reloaded, now: now))
        let before = error(calibrated), after = error(outcome.model)
        #expect(after < before * 0.7, "error before \(before) mm, after \(after) mm")
        // Better than learning from clicks without relearning the personalization.
        #expect(after < error(plain), "\(after) mm vs \(error(plain)) mm")
    }

    /// Frames from following the moving dot, grouped into stretches as calibration does, with
    /// the head drifting slowly.
    func pursuitSamples(scene: SyntheticScene, plane: DisplayPlane, displayIndex: Int = 0, seed: UInt64) -> [CalibrationSample] {
        var rng = SeededGenerator(seed: seed)
        var result: [CalibrationSample] = []
        for frame in 30..<Int(PursuitPath.duration(.sweep) * 30) {
            let t = Double(frame) / 30
            let point = PursuitPath.point(.sweep, in: plane.frame, at: t)
            let local = plane.local(from: point)
            let head = SyntheticScene.head(
                offset: Vec3(40 * sin(t / 3), 20 * cos(t / 4), 50 * sin(t / 5)),
                rotation: Vec3(0, .random(in: -0.05...0.05, using: &rng), 0)
            )
            result.append(CalibrationSample(
                measurements: scene.measurements(head: head, lookingAt: plane.origin + plane.xAxis * local.x + plane.yAxis * local.y, time: 1000 + t, using: &rng),
                target: point,
                targetIndex: 10_000 + frame / 15,
                displayIndex: displayIndex
            ))
        }
        return result
    }

    /// A network that's off for this person in a way that varies across the screen: the
    /// calibration dots pin it down at nine spots, the moving dot everywhere it passes.
    @Test func followingTheMovingDotPersonalizesBetter() throws {
        var scene = SyntheticScene.realistic
        scene.networkNoise = 0.01
        var rng = SeededGenerator(seed: 41)
        let mixing = (0..<48).map { _ in (Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng)) }
        scene.networkFeatures = { g in mixing.map { m in tanh(m.0 * Float(g.x) * 6 + m.1 * Float(g.y) * 6 + m.2) } }
        scene.networkPersonalError = { g in SIMD2(0.02 + 0.3 * g.x + 2 * g.y * g.y, -0.03 - 0.25 * g.y + 3 * g.x * g.y) }

        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let dots = samples(scene: scene, planes: planes, seed: 42, framesPerTarget: 6)
        let withDots = try #require(GazeModel.fit(dots, displays: [laptop], source: .network))
        let withPursuit = try #require(GazeModel.fit(dots + pursuitSamples(scene: scene, plane: planes[0], seed: 43), displays: [laptop], source: .network))
        let before = heldOutError(model: withDots, scene: scene, planes: planes)
        let after = heldOutError(model: withPursuit, scene: scene, planes: planes)
        #expect(after < before * 0.8, "dots alone \(before) mm, with the moving dot \(after) mm")
    }

    /// Estimates that bend toward the middle near the screen's corners, which a linear eye
    /// correction can't follow: the moving dot's coverage lets calibration fit the curvature.
    @Test func fitsCurvatureWhenTheMovingDotCoversTheScreen() throws {
        var scene = SyntheticScene()
        scene.distortion = { v in SIMD2(-0.6 * v.x * v.y, -0.4 * v.x * v.x) }
        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let dots = samples(scene: scene, planes: planes, seed: 45, framesPerTarget: 6)
        #expect(try #require(GazeModel.fit(dots, displays: [laptop])).eye.count == 6, "too few targets to pin curvature down")
        let all = dots + pursuitSamples(scene: scene, plane: planes[0], seed: 46)
        let curved = try #require(GazeModel.fit(all, displays: [laptop]))
        let linear = try #require(GazeModel.fit(all, displays: [laptop], curvedEye: false))
        #expect(curved.eye.count == 12)
        let a = heldOutError(model: linear, scene: scene, planes: planes), b = heldOutError(model: curved, scene: scene, planes: planes)
        #expect(b < a * 0.8, "linear \(a) mm, curved \(b) mm")
        // Saved and loaded with the extra terms.
        #expect(try JSONDecoder().decode(GazeModel.self, from: JSONEncoder().encode(curved)) == curved)
    }

    @Test(arguments: [PursuitPath.Kind.sweep, .loops])
    func pursuitPathsAreSmoothAndCoverTheScreen(kind: PursuitPath.Kind) {
        let frame = CGRect(x: 100, y: 50, width: 1728, height: 1117)
        var visited = Set<Int>()
        var previous = PursuitPath.point(kind, in: frame, at: 0)
        var fastest = 0.0
        var nearestCorner = [Double](repeating: .infinity, count: 4)
        let corners = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)]
        for i in 1...Int(PursuitPath.duration(kind) * 60) {
            let point = PursuitPath.point(kind, in: frame, at: Double(i) / 60)
            #expect(frame.insetBy(dx: frame.width * 0.04, dy: frame.height * 0.04).contains(point))
            fastest = max(fastest, hypot(point.x - previous.x, point.y - previous.y) * 60)
            previous = point
            visited.insert(Int((point.x - frame.minX) / frame.width * 4) * 4 + Int((point.y - frame.minY) / frame.height * 4))
            for (c, corner) in corners.enumerated() { nearestCorner[c] = min(nearestCorner[c], hypot(point.x - corner.x, point.y - corner.y)) }
        }
        // Smooth pursuit keeps up to about 30° a second; at 55 cm on a 0.2 mm point that's 1500 pt.
        #expect(fastest < 900, "\(fastest) pt/s")
        switch kind {
        case .sweep:
            #expect(visited.count == 16, "visits \(visited.count) of 16 regions")
        case .loops:
            // Into every corner, which the sweep doesn't quite reach.
            #expect(nearestCorner.allSatisfy { $0 < 200 }, "\(nearestCorner)")
            #expect(visited.count >= 12, "visits \(visited.count) of 16 regions")
        }
    }

    /// The camera's real field of view, when known, explains head motion better than a typical one.
    @Test func calibratesWithTheFieldOfViewItIsGiven() throws {
        var scene = SyntheticScene.realistic
        scene.fieldOfView = 90
        scene.networkNoise = 0.005
        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let calibration = samples(scene: scene, planes: planes, seed: 44, framesPerTarget: 6)
        let typical = try #require(GazeModel.fit(calibration, displays: [laptop], source: .network))
        let known = try #require(GazeModel.fit(calibration, displays: [laptop], source: .network, fieldOfView: 90))
        #expect(known.fieldOfView == 90)
        #expect(typical.fieldOfView == GazeModel.defaultFieldOfView)
        let a = heldOutError(model: typical, scene: scene, planes: planes), b = heldOutError(model: known, scene: scene, planes: planes)
        #expect(b < a, "typical \(a) mm, known \(b) mm")
    }

    @Test func placesExternalDisplay() throws {
        let scene = SyntheticScene()
        var planes = GazeModel.initialPlanes(for: [laptop, monitor]).planes
        // The real monitor sits behind the laptop and is tilted back, unlike the initial guess.
        planes[1] = planes[1].moved(rotation: Vec3(0.12, 0.05, 0), translation: Vec3(40, 60, -180))
        let model = try #require(GazeModel.fit(samples(scene: scene, planes: planes, seed: 2), displays: [laptop, monitor]))
        #expect(heldOutError(model: model, scene: scene, planes: planes) < 12)
    }

    /// Everyday click events on `plane`: each a few frames of settled gaze from one head pose.
    /// Every `missEvery`th click is made without looking at the cursor.
    func clickEvents(
        scene: SyntheticScene,
        plane: DisplayPlane,
        model: GazeModel,
        count: Int,
        framesPerEvent: Int = 1,
        missEvery: Int = 5,
        seed: UInt64
    ) -> [InteractionSample] {
        var rng = SeededGenerator(seed: seed)
        let estimator = HeadPoseEstimator()
        var result: [InteractionSample] = []
        for i in 0..<count {
            func randomSpot() -> SIMD2<Double> {
                SIMD2(.random(in: 0.05...0.95, using: &rng), .random(in: 0.05...0.95, using: &rng)) * plane.size
            }
            let looked = randomSpot()
            let clicked = i % missEvery == 0 ? randomSpot() : looked
            let offset = Vec3(.random(in: -50...50, using: &rng), .random(in: -30...30, using: &rng), .random(in: -60...60, using: &rng))
            let yaw = Double.random(in: -0.15...0.15, using: &rng)
            let event = UUID()
            let date = Date(timeIntervalSince1970: 1_000_000 + Double(i) * 60)
            for f in 0..<framesPerEvent {
                let m = scene.measurements(
                    head: SyntheticScene.head(offset: offset + Vec3(Double(f), 0, 0), rotation: Vec3(0, yaw, 0)),
                    lookingAt: plane.origin + plane.xAxis * looked.x + plane.yAxis * looked.y,
                    time: Double(i) * 10 + Double(f) / 30
                )
                guard let (_, observation) = m.observe(for: model, using: estimator) else { continue }
                result.append(InteractionSample(
                    observation: observation,
                    target: plane.point(fromLocal: clicked),
                    displayID: plane.displayID,
                    source: .click,
                    date: date,
                    event: event
                ))
            }
        }
        return result
    }

    @Test func adaptsToDriftFromClicks() throws {
        let scene = SyntheticScene()
        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let plane = planes[0]
        let calibrated = try #require(GazeModel.fit(samples(scene: scene, planes: planes, seed: 4), displays: [laptop]))
        #expect(calibrated.anchorDisplayID == laptop.displayID)

        // Later the user's eyes behave differently, e.g. after sitting differently or putting on glasses.
        var drifted = scene
        drifted.eye = [0.06, 1.05, 0, -0.045, 1, 0]

        let interactions = clickEvents(scene: drifted, plane: plane, model: calibrated, count: 80, seed: 5)
        let now = interactions.map(\.date).max()!

        let before = heldOutError(model: calibrated, scene: drifted, planes: planes)
        let adapted = try #require(GazeModel.adapt(calibrated, to: interactions, now: now))
        let after = heldOutError(model: adapted, scene: drifted, planes: planes)
        #expect(after < before / 2, "error before \(before) mm, after \(after) mm")
        #expect(after < 8)

        // The learner's refit judges on held-out clicks, and should adopt this improvement.
        let outcome = try #require(LearningFit.refit(base: calibrated, current: calibrated, samples: interactions, now: now, recencyHalfLife: 7 * 86400))
        #expect(outcome.after < outcome.before)
    }

    @Test func correctionLayerLearnsWhatGeometryCannot() throws {
        var scene = SyntheticScene()
        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let plane = planes[0]
        let calibrated = try #require(GazeModel.fit(samples(scene: scene, planes: planes, seed: 6), displays: [laptop]))

        // Eye-angle error that bends differently across the screen: beyond an affine correction.
        scene.distortion = { a in SIMD2(0.9 * a.x * a.y, 0.6 * a.x * a.x) }
        let interactions = clickEvents(scene: scene, plane: plane, model: calibrated, count: 220, framesPerEvent: 3, missEvery: 10, seed: 7)
        let now = interactions.map(\.date).max()!

        let adapted = try #require(GazeModel.adapt(calibrated, to: interactions, now: now))
        #expect(adapted.corrections?.count == 1)
        var geometryOnly = adapted
        geometryOnly.corrections = nil
        let withLayer = heldOutError(model: adapted, scene: scene, planes: planes)
        let without = heldOutError(model: geometryOnly, scene: scene, planes: planes)
        #expect(withLayer < without * 0.7, "with correction layer \(withLayer) mm, geometry only \(without) mm")
    }

    @Test func correctionLayerWaitsForEnoughData() throws {
        let scene = SyntheticScene()
        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let calibrated = try #require(GazeModel.fit(samples(scene: scene, planes: planes, seed: 8), displays: [laptop]))
        let few = clickEvents(scene: scene, plane: planes[0], model: calibrated, count: 30, framesPerEvent: 3, seed: 9)
        #expect(GazeModel.adapt(calibrated, to: few, now: few.map(\.date).max()!)?.corrections == nil)
    }

    @Test func weightsBalanceCrowdedRegionsAndDecayWithAge() {
        let plane = GazeModel.initialPlanes(for: [laptop]).planes[0]
        let observation = GazeObservation(origin: Vec3(0, -100, 550), headRotation: matrix_identity_double3x3, eyeAngles: .zero)
        let now = Date(timeIntervalSince1970: 10_000_000)
        func sample(at fraction: SIMD2<Double>, age: TimeInterval = 0) -> InteractionSample {
            InteractionSample(observation: observation, target: plane.point(fromLocal: fraction * plane.size), displayID: plane.displayID, source: .click, date: now - age)
        }
        // Ten clicks in one corner, one elsewhere, and one old click elsewhere.
        let samples = (0..<10).map { _ in sample(at: SIMD2(0.1, 0.1)) } + [sample(at: SIMD2(0.9, 0.9)), sample(at: SIMD2(0.5, 0.9), age: 14 * 86400)]
        let w = GazeModel.learningWeights(samples, planes: [plane], planeIndex: [plane.displayID: 0], now: now, halfLife: 7 * 86400)
        #expect(w[0] < w[10], "a click in a crowded region counts less than an isolated one")
        #expect(abs(w[11] / w[10] - 0.25) < 1e-9, "two half-lives old counts a quarter")
    }

    @Test func decodesInteractionSamplesSavedBeforeEvents() throws {
        let json = """
        {"observation":{"origin":[1,2,3],"headRotation":[1,0,0,0,1,0,0,0,1],"eyeAngles":[0.1,0.2]},
         "target":[10,20],"displayID":1,"source":"click","date":0}
        """
        let sample = try JSONDecoder().decode(InteractionSample.self, from: Data(json.utf8))
        #expect(sample.source == .click)
        #expect(sample.observation.eyeAngles == SIMD2(0.1, 0.2))
    }

    @Test func interactionSamplesRoundTripThroughJSON() throws {
        let sample = InteractionSample(
            observation: GazeObservation(origin: Vec3(1, 2, 3), headRotation: Rotation.matrix(Vec3(0.1, -0.2, 0.05)), eyeAngles: SIMD2(0.1, -0.05)),
            target: CGPoint(x: 100, y: 200),
            displayID: 1,
            source: .typing,
            date: Date(timeIntervalSince1970: 1000)
        )
        let decoded = try JSONDecoder().decode(InteractionSample.self, from: JSONEncoder().encode(sample))
        #expect(decoded == sample)
    }

    @Test func roundTripsThroughJSON() throws {
        let model = GazeModel(eye: [0.01, 1.1, 0, 0, 0.9, 0.02], planes: GazeModel.initialPlanes(for: [laptop, monitor]).planes, fieldOfView: 75)
        let decoded = try JSONDecoder().decode(GazeModel.self, from: JSONEncoder().encode(model))
        #expect(decoded == model)
    }

    @Test func profilesRoundTripAndKeepIdentityWhenRecalibrated() throws {
        let model = GazeModel(planes: GazeModel.initialPlanes(for: [laptop, monitor]).planes)
        var profile = CalibrationProfile(signature: "abc", displays: [monitor, laptop], model: model, validation: nil)
        #expect(profile.name == "Built-in + External")
        profile.name = "Home desk"
        profile.interactions = [InteractionSample(observation: GazeObservation(origin: Vec3(1, 2, 3), headRotation: matrix_identity_double3x3, eyeAngles: .zero), target: .zero, displayID: 1, source: .click, date: .now)]
        let decoded = try JSONDecoder().decode(CalibrationProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)

        var recalibrated = decoded
        recalibrated.recalibrate(model: model, validation: nil, samples: [], displays: [laptop, monitor], signature: "abc")
        #expect(recalibrated.id == profile.id && recalibrated.name == "Home desk")
        #expect(recalibrated.interactions == [])
    }

    @Test func keepsTheNetworkModeItWasCalibratedWith() throws {
        let model = GazeModel(planes: GazeModel.initialPlanes(for: [laptop]).planes, source: .network)
        #expect(model.averagesMirroredNetwork)
        // Profiles from before mirroring were calibrated on the plain network, and must keep it.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as! [String: Any]
        json["networkMirrored"] = nil
        let older = try JSONDecoder().decode(GazeModel.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!older.averagesMirroredNetwork)
    }

    @Test func decodesProfilesSavedBeforeNamedProfiles() throws {
        let model = GazeModel(planes: GazeModel.initialPlanes(for: [laptop]).planes)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CalibrationProfile(signature: "abc", displays: [laptop], model: model, validation: nil))) as! [String: Any]
        json["id"] = nil
        json["name"] = nil
        json["lastUsed"] = nil
        let decoded = try JSONDecoder().decode(CalibrationProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.name == "Built-in")
        #expect(decoded.signature == "abc")
    }

    @Test func requiresSeveralTargets() {
        let scene = SyntheticScene()
        let planes = GazeModel.initialPlanes(for: [laptop]).planes
        let few = samples(scene: scene, planes: planes, seed: 3).filter { $0.targetIndex < 2 }
        #expect(GazeModel.fit(few, displays: [laptop]) == nil)
    }

    @Test func builtInPlaneSitsBelowCamera() {
        let plane = GazeModel.initialPlanes(for: [laptop]).planes[0]
        // From the user's view, the top-left corner is at camera +x (the user's left), just below the camera.
        #expect(plane.origin.x > 0 && plane.origin.y < 0)
        #expect(abs(plane.origin.x - plane.size.x / 2) < 1e-9)
        #expect(plane.local(from: CGPoint(x: 0, y: 956)) == .zero)
    }
}

struct LeastSquaresTests {
    @Test func fitsCurve() {
        // y = a·exp(b·x)
        let xs = stride(from: 0.0, through: 2, by: 0.1).map { $0 }
        let ys = xs.map { 2.5 * exp(-1.3 * $0) }
        let p = LeastSquares.minimize([1, 0], steps: [1e-6, 1e-6]) { p in
            zip(xs, ys).map { p[0] * exp(p[1] * $0) - $1 }
        }
        #expect(abs(p[0] - 2.5) < 1e-4)
        #expect(abs(p[1] + 1.3) < 1e-4)
    }
}

struct GazeStabilizerTests {
    /// Gaussian scatter around a point, as tracking noise.
    func noisy(_ p: CGPoint, sigma: Double, rng: inout SeededGenerator) -> CGPoint {
        func gaussian() -> Double {
            let u1 = Double.random(in: 1e-12...1, using: &rng), u2 = Double.random(in: 0...1, using: &rng)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        return CGPoint(x: p.x + sigma * gaussian(), y: p.y + sigma * gaussian())
    }

    @Test func holdsStillDuringAFixation() {
        var rng = SeededGenerator(seed: 1)
        var stabilizer = GazeStabilizer(steadiness: 0.6)
        let spot = CGPoint(x: 500, y: 400)
        var outputs: [CGPoint] = []
        for i in 0..<120 {
            outputs.append(stabilizer.update(noisy(spot, sigma: 30, rng: &rng), at: Double(i) / 30))
        }
        // After settling, the point moves far less than the 30 pt per-frame noise.
        let settled = outputs.suffix(60)
        let steps = zip(settled, settled.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        #expect(steps.max()! < 4)
        #expect(settled.allSatisfy { hypot($0.x - spot.x, $0.y - spot.y) < 15 })
    }

    @Test func jumpsPromptlyToANewSpot() {
        var rng = SeededGenerator(seed: 2)
        var stabilizer = GazeStabilizer(steadiness: 0.6)
        let first = CGPoint(x: 300, y: 300), second = CGPoint(x: 1100, y: 600)
        var time = 0.0
        for _ in 0..<60 {
            _ = stabilizer.update(noisy(first, sigma: 30, rng: &rng), at: time)
            time += 1.0 / 30
        }
        var framesToArrive: Int?
        for frame in 1...15 {
            let p = stabilizer.update(noisy(second, sigma: 30, rng: &rng), at: time)
            time += 1.0 / 30
            if framesToArrive == nil, hypot(p.x - second.x, p.y - second.y) < 60 {
                framesToArrive = frame
            }
        }
        // Within about a sixth of a second.
        #expect((framesToArrive ?? 99) <= 5)
    }

    @Test func learnsTheNoiseLevelWithoutDrifting() {
        var rng = SeededGenerator(seed: 4)
        for steadiness in [0.0, 1.0] {
            var stabilizer = GazeStabilizer(steadiness: steadiness)
            for i in 0..<1800 {
                _ = stabilizer.update(noisy(CGPoint(x: 500, y: 400), sigma: 25, rng: &rng), at: Double(i) / 30)
            }
            #expect(abs(stabilizer.noise - 25) < 4, "steadiness \(steadiness): estimated \(stabilizer.noise) pt")
        }
    }

    /// Looking at one spot while turning the head back and forth: the eyes counter-rotate, so the
    /// raw gaze stays put even though the head-driven shift is large.
    @Test func holdsStillWhileTheHeadMovesAndTheEyesHoldASpot() {
        let spot = CGPoint(x: 500, y: 400)
        func worstDeviation(headSpeed: Double) -> (worst: Double, carry: Double) {
            var rng = SeededGenerator(seed: 5)
            var stabilizer = GazeStabilizer(steadiness: 0.6)
            var outputs: [CGPoint] = []
            for i in 0..<150 {
                let shift = CGVector(dx: headSpeed * cos(Double(i) / 6), dy: 0)
                outputs.append(stabilizer.update(noisy(spot, sigma: 30, rng: &rng), headShift: shift, at: Double(i) / 30))
            }
            return (outputs.suffix(90).map { hypot($0.x - spot.x, $0.y - spot.y) }.max()!, stabilizer.carry)
        }
        let still = worstDeviation(headSpeed: 0)
        let moving = worstDeviation(headSpeed: 25)
        // About as steady as with the head still, and not mistaken for gaze following the head.
        #expect(moving.worst < still.worst + 10, "head still \(still.worst) pt, moving \(moving.worst) pt")
        #expect(moving.carry < 0.3)
    }

    /// Turning the head toward another screen with the eyes still in the head: the gaze point
    /// moves with the head, and the stabilizer should follow smoothly instead of lagging and jumping.
    @Test func followsGazeCarriedByTheHead() {
        var rng = SeededGenerator(seed: 6)
        var stabilizer = GazeStabilizer(steadiness: 0.6)
        var truth = CGPoint(x: 300, y: 400)
        var time = 0.0
        for _ in 0..<30 {
            _ = stabilizer.update(noisy(truth, sigma: 30, rng: &rng), at: time)
            time += 1.0 / 30
        }
        var errors: [Double] = []
        var steps: [Double] = []
        var last = truth
        let shift = CGVector(dx: 20, dy: 0) // 600 pt/s
        for _ in 0..<45 {
            truth.x += shift.dx
            let p = stabilizer.update(noisy(truth, sigma: 30, rng: &rng), headShift: shift, at: time)
            time += 1.0 / 30
            errors.append(hypot(p.x - truth.x, p.y - truth.y))
            steps.append(hypot(p.x - last.x, p.y - last.y))
            last = p
        }
        // Once the motion is recognized (and the one catch-up step taken), it tracks closely and
        // moves at the head's pace, without jumps.
        #expect(errors.suffix(25).max()! < 45, "errors \(errors.suffix(25).map { Int($0) })")
        #expect(steps.suffix(25).max()! < 40, "steps \(steps.suffix(25).map { Int($0) })")
        #expect(stabilizer.carry > 0.7)
    }

    /// A large gaze shift is accepted within two frames, head still or turning.
    @Test func jumpsWithinTwoFrames() {
        func framesToArrive(headShift: CGVector) -> Int {
            var rng = SeededGenerator(seed: 7)
            var stabilizer = GazeStabilizer(steadiness: 0.6)
            let first = CGPoint(x: 300, y: 300), second = CGPoint(x: 1100, y: 600)
            var time = 0.0
            for _ in 0..<60 {
                _ = stabilizer.update(noisy(first, sigma: 30, rng: &rng), at: time)
                time += 1.0 / 30
            }
            for frame in 1...15 {
                let p = stabilizer.update(noisy(second, sigma: 30, rng: &rng), headShift: headShift, at: time)
                time += 1.0 / 30
                if hypot(p.x - second.x, p.y - second.y) < 60 { return frame }
            }
            return 99
        }
        let still = framesToArrive(headShift: .zero)
        let turning = framesToArrive(headShift: CGVector(dx: 30, dy: 10))
        #expect(still <= 2 && turning <= 2, "head still \(still) frames, turning \(turning)")
    }

    /// A shift smaller than the scatter of single frames (here 1.7σ, as when glancing a few
    /// centimeters up on a laptop screen) is still picked up from frames taken together.
    @Test func followsAShiftSmallerThanTheNoise() {
        var rng = SeededGenerator(seed: 8)
        var stabilizer = GazeStabilizer(steadiness: 0.6)
        let first = CGPoint(x: 500, y: 400), second = CGPoint(x: 500, y: 450)
        var time = 0.0
        // Long enough for the noise estimate to settle.
        for _ in 0..<300 {
            _ = stabilizer.update(noisy(first, sigma: 30, rng: &rng), at: time)
            time += 1.0 / 30
        }
        var framesToArrive: Int?
        for frame in 1...30 {
            let p = stabilizer.update(noisy(second, sigma: 30, rng: &rng), at: time)
            time += 1.0 / 30
            if framesToArrive == nil, hypot(p.x - second.x, p.y - second.y) < 20 { framesToArrive = frame }
        }
        // Within about two thirds of a second.
        #expect((framesToArrive ?? 99) <= 20, "\(framesToArrive ?? 99) frames")
    }

    /// Testing for shifts every frame mustn't make a steady gaze wander.
    @Test func rarelyJumpsDuringALongFixation() {
        var rng = SeededGenerator(seed: 9)
        var stabilizer = GazeStabilizer(steadiness: 0.6)
        let spot = CGPoint(x: 500, y: 400)
        var last: CGPoint?
        var jumps = 0
        for i in 0..<1800 { // a minute
            let p = stabilizer.update(noisy(spot, sigma: 30, rng: &rng), at: Double(i) / 30)
            if i > 60, let last, hypot(p.x - last.x, p.y - last.y) > 20 { jumps += 1 }
            last = p
        }
        #expect(jumps <= 3, "\(jumps) jumps")
    }

    @Test func ignoresAStrayFrame() {
        var rng = SeededGenerator(seed: 3)
        var stabilizer = GazeStabilizer(steadiness: 0.6)
        let spot = CGPoint(x: 500, y: 400)
        var time = 0.0
        var before = CGPoint.zero
        for _ in 0..<60 {
            before = stabilizer.update(noisy(spot, sigma: 30, rng: &rng), at: time)
            time += 1.0 / 30
        }
        let after = stabilizer.update(CGPoint(x: 1400, y: 900), at: time)
        #expect(hypot(after.x - before.x, after.y - before.y) < 1)
    }
}

struct DisplayTests {
    let displays = [
        DisplayInfo(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), millimetersPerPoint: 0.2, vendor: 1, model: 1, serial: 1, name: "Built-in"),
        DisplayInfo(displayID: 2, frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440), millimetersPerPoint: 0.23, vendor: 2, model: 2, serial: 2, name: "External"),
    ]

    @Test func signatureIgnoresOrder() {
        #expect(DisplayInfo.signature(of: displays) == DisplayInfo.signature(of: displays.reversed()))
        #expect(DisplayInfo.signature(of: displays) != DisplayInfo.signature(of: [displays[0]]))
    }

    @Test func clampsToNearestDisplay() {
        #expect(displays.clamp(CGPoint(x: -50, y: 450)) == CGPoint(x: 0, y: 450))
        #expect(displays.clamp(CGPoint(x: 2000, y: 1600)) == CGPoint(x: 2000, y: 1439))
        #expect(displays.clamp(CGPoint(x: 500, y: 500)) == CGPoint(x: 500, y: 500))
    }
}

/// Deterministic RNG so the synthetic tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}


struct FaceNormalizationTests {
    let scene = SyntheticScene()

    func normalization(_ head: HeadPose) throws -> FaceNormalization {
        try #require(FaceNormalization(head: head, face: .generic, intrinsics: scene.intrinsics, imageHeight: scene.imageSize.y))
    }

    /// Image pixel (lower-left origin) → patch pixel (top-left origin).
    func patchPoint(_ n: FaceNormalization, _ image: SIMD2<Double>) -> SIMD2<Double> {
        let p = n.patchToImage.inverse * Vec3(image.x, scene.imageSize.y - image.y, 1)
        return SIMD2(p.x / p.z, p.y / p.z)
    }

    /// The incremental warp gives the same patch as mapping every pixel through the full matrix.
    @Test func rendersPatchLikeThePerPixelMap() throws {
        let n = try normalization(SyntheticScene.head(offset: Vec3(30, -10, 20), rotation: Vec3(0.1, -0.15, 0.2)))
        let width = 1920, height = 1080
        var frame: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &frame)
        var patch: CVPixelBuffer?
        CVPixelBufferCreate(nil, FaceNormalization.patchSize, FaceNormalization.patchSize, kCVPixelFormatType_32BGRA, nil, &patch)
        let source = try #require(frame), output = try #require(patch)

        CVPixelBufferLockBaseAddress(source, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(source, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(source, 1)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(source, 0), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        for y in 0..<height {
            for x in 0..<width { luma[y * lumaRow + x] = UInt8((x * 7 + y * 13 + (x * y) % 31) & 255) }
        }
        for y in 0..<height / 2 {
            for x in 0..<width { chroma[y * chromaRow + x] = UInt8((x * 3 + y * 5) & 255) }
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        #expect(PatchRenderer.render(source, into: output, normalization: n))

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(output, .readOnly)
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let out = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let outRow = CVPixelBufferGetBytesPerRow(output)
        func lumaAt(_ x: Int, _ y: Int) -> Double { Double(luma[min(max(y, 0), height - 1) * lumaRow + min(max(x, 0), width - 1)]) }
        var worst = 0
        for py in 0..<FaceNormalization.patchSize {
            for px in 0..<FaceNormalization.patchSize {
                let p = n.imagePoint(patchX: Double(px) + 0.5, patchY: Double(py) + 0.5)
                let fx = p.x - 0.5, fy = p.y - 0.5
                let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                let ax = fx - Double(x0), ay = fy - Double(y0)
                let top = lumaAt(x0, y0) * (1 - ax) + lumaAt(x0 + 1, y0) * ax
                let bottom = lumaAt(x0, y0 + 1) * (1 - ax) + lumaAt(x0 + 1, y0 + 1) * ax
                let yValue = top * (1 - ay) + bottom * ay
                let cx = min(max(Int(p.x / 2), 0), width / 2 - 1), cy = min(max(Int(p.y / 2), 0), height / 2 - 1)
                let u = Double(chroma[cy * chromaRow + cx * 2]) - 128, v = Double(chroma[cy * chromaRow + cx * 2 + 1]) - 128
                let expected = [yValue + 1.8556 * u, yValue - 0.187324 * u - 0.468124 * v, yValue + 1.5748 * v]
                for c in 0..<3 {
                    let e = Int(min(max(expected[c].rounded(), 0), 255))
                    worst = max(worst, abs(Int(out[py * outRow + px * 4 + c]) - e))
                }
            }
        }
        #expect(worst <= 1)
    }

    @Test func centersTheFaceUpright() throws {
        let head = SyntheticScene.head(rotation: Vec3(0, 0, 0.3)) // rolled
        let n = try normalization(head)
        let face = FaceShape.generic
        let left = patchPoint(n, scene.intrinsics.project(head.toCamera((face.landmarks[0] + face.landmarks[1]) / 2)))
        let right = patchPoint(n, scene.intrinsics.project(head.toCamera((face.landmarks[2] + face.landmarks[3]) / 2)))
        let mouth = patchPoint(n, scene.intrinsics.project(head.toCamera((face.landmarks[5] + face.landmarks[6]) / 2)))
        // Roll removed: the eyes level, the image-left eye on the left, the mouth below.
        #expect(abs(left.y - right.y) < 0.5)
        #expect(left.x < right.x)
        #expect(mouth.y > left.y)
        // Seen from 60 cm with a 960 px focal length, the eyes are about 100 px apart.
        #expect(abs((right.x - left.x) - 960 * 63 / 600) < 15)
        let mid = (left + right) / 2
        #expect(abs(mid.x - 112) < 3)
    }

    @Test func zeroAnglesLookAtTheCamera() throws {
        let head = SyntheticScene.head(offset: Vec3(60, 20, 0), rotation: Vec3(0.1, 0.2, 0))
        let n = try normalization(head)
        let face = FaceShape.generic
        let eyes = (face.landmarks[0] + face.landmarks[1] + face.landmarks[2] + face.landmarks[3]) / 4
        let center = head.toCamera((eyes + face.landmarks[4] + Vec3(0, -5, 12)) / 2)
        #expect(simd_length(n.gazeDirection(pitch: 0, yaw: 0) + simd_normalize(center)) < 1e-9)
        // Positive pitch looks up.
        #expect(n.gazeDirection(pitch: 0.2, yaw: 0).y > n.gazeDirection(pitch: 0, yaw: 0).y)
    }
}

struct FeatureCorrectionTests {
    /// A person-specific error (here a gain and offset in each angle) is learned from features that
    /// encode the gaze, and predicted for targets left out.
    @Test func learnsErrorsFromFeatures() throws {
        var rng = SeededGenerator(seed: 21)
        // Features: the gaze angles mixed into 64 values, plus noise.
        let mixing = (0..<64).map { _ in SIMD2(Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng)) }
        func features(_ gaze: SIMD2<Double>) -> [Float] {
            mixing.map { $0.x * Float(gaze.x) * 5 + $0.y * Float(gaze.y) * 5 + Float.random(in: -0.1...0.1, using: &rng) }
        }
        func error(_ gaze: SIMD2<Double>) -> SIMD2<Double> { SIMD2(0.03 + 0.2 * gaze.x, -0.02 - 0.15 * gaze.y) }
        var all: [[Float]] = [], residuals: [SIMD2<Double>] = [], groups: [Int] = []
        for target in 0..<12 {
            let gaze = SIMD2(Double(target % 4) / 3 - 0.5, Double(target / 4) / 2 - 0.5) * 0.6
            for _ in 0..<10 {
                all.append(features(gaze))
                residuals.append(error(gaze))
                groups.append(target)
            }
        }
        let (correction, heldOut, baseline) = try #require(FeatureCorrection.fit(features: all, residuals: residuals, groups: groups))
        #expect(heldOut < baseline / 3, "held out \(heldOut), uncorrected \(baseline)")
        let probe = SIMD2(0.12, -0.08)
        #expect(simd_length(correction.correction(for: features(probe)) - error(probe)) < 0.005)
    }

    @Test func normalizedAnglesRoundTrip() throws {
        let scene = SyntheticScene()
        let head = SyntheticScene.head(offset: Vec3(40, -20, 30), rotation: Vec3(0.1, -0.2, 0.15))
        let n = try #require(FaceNormalization(head: head, face: .generic, intrinsics: scene.intrinsics, imageHeight: scene.imageSize.y))
        let angles = SIMD2(-0.3, 0.25)
        let back = n.angles(of: n.gazeDirection(pitch: angles.x, yaw: angles.y))
        #expect(simd_length(back - angles) < 1e-9)
    }
}

struct WindowTargetingTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let editor = ScreenWindow(id: 1, pid: 10, frame: CGRect(x: 0, y: 0, width: 900, height: 982), appName: "Editor")
    let browser = ScreenWindow(id: 2, pid: 20, frame: CGRect(x: 900, y: 0, width: 612, height: 982), appName: "Browser")

    @Test func picksTheWindowUnderTheGaze() {
        let target = WindowTargeting.target(gaze: CGPoint(x: 1200, y: 500), sigma: 60, windows: [editor, browser], displays: [screen])
        #expect(target == .window(browser))
    }

    @Test func refusesToGuessOnABorder() {
        let target = WindowTargeting.target(gaze: CGPoint(x: 905, y: 500), sigma: 60, windows: [editor, browser], displays: [screen])
        #expect(target == .ambiguous(browser, editor) || target == .ambiguous(editor, browser))
    }

    @Test func onlyCountsTheVisiblePart() {
        // A small window in front of a big one: gaze on the small one picks it, not the one behind.
        let palette = ScreenWindow(id: 3, pid: 30, frame: CGRect(x: 300, y: 300, width: 400, height: 400), appName: "Palette")
        let target = WindowTargeting.target(gaze: CGPoint(x: 500, y: 500), sigma: 50, windows: [palette, editor], displays: [screen])
        #expect(target == .window(palette))
    }

    @Test func screenEdgesDontDiluteTheGaze() {
        // A window along the right edge, gaze at the edge: half the blur is off screen, which
        // shouldn't count against the window.
        let target = WindowTargeting.target(gaze: CGPoint(x: 1505, y: 500), sigma: 60, windows: [editor, browser], displays: [screen])
        #expect(target == .window(browser))
    }

    @Test func forgivesGazeNearABorder() {
        // A blur's width from the border, most of it on the browser: picked, not refused.
        let target = WindowTargeting.target(gaze: CGPoint(x: 960, y: 500), sigma: 60, windows: [editor, browser], displays: [screen])
        #expect(target == .window(browser))
    }

    @Test func keepsTheOutlinedWindowAtABorder() {
        // Just across the border, the browser leads, but not clearly: the editor stays outlined.
        let gazes = [CGPoint(x: 910, y: 500)]
        #expect(WindowTargeting.target(gazes: gazes, sigma: 60, windows: [editor, browser], displays: [screen], keeping: editor.id) == .window(editor))
        // Well across, it switches.
        #expect(WindowTargeting.target(gazes: [CGPoint(x: 1000, y: 500)], sigma: 60, windows: [editor, browser], displays: [screen], keeping: editor.id) == .window(browser))
    }

    @Test func averagesOverRecentGaze() {
        // One stray point on the border doesn't undo several clearly on the browser.
        let gazes = [CGPoint(x: 1000, y: 500), CGPoint(x: 990, y: 510), CGPoint(x: 905, y: 500)]
        #expect(WindowTargeting.target(gazes: gazes, sigma: 60, windows: [editor, browser], displays: [screen]) == .window(browser))
    }

    @Test func findsWindowsBuriedBehindTheFocusedOne() {
        let big = ScreenWindow(id: 10, pid: 1, frame: CGRect(x: 0, y: 0, width: 1400, height: 900), appName: "Big")
        let buried = ScreenWindow(id: 11, pid: 2, frame: CGRect(x: 200, y: 200, width: 500, height: 400), appName: "Buried")
        let peeking = ScreenWindow(id: 12, pid: 3, frame: CGRect(x: 1300, y: 100, width: 300, height: 300), appName: "Peeking")
        let elsewhere = ScreenWindow(id: 13, pid: 4, frame: CGRect(x: 1420, y: 0, width: 90, height: 900), appName: "Elsewhere")
        let deeper = ScreenWindow(id: 14, pid: 5, frame: CGRect(x: 220, y: 220, width: 450, height: 350), appName: "Deeper")
        let found = WindowTargeting.buried(behind: big.id, windows: [big, buried, peeking, elsewhere, deeper])
        // Fully hidden: shown. Mostly visible beside it, not under it at all, or under another
        // buried window (a second layer): left out.
        #expect(found == [buried])
    }

    @Test func stricterThresholdsRefuseNearBorders() {
        // Half a blur inside the browser: about 2× the editor's share.
        let gaze = [CGPoint(x: 930, y: 500)]
        #expect(WindowTargeting.target(gazes: gaze, sigma: 60, windows: [editor, browser], displays: [screen]) == .window(browser))
        let strict = WindowTargeting.Thresholds(minimumShare: 0.5, minimumLead: 4)
        #expect(WindowTargeting.target(gazes: gaze, sigma: 60, windows: [editor, browser], displays: [screen], thresholds: strict) != .window(browser))
    }

    @Test func tuningDecodesOlderSettings() throws {
        // Saved before most settings existed: the rest take their defaults.
        let tuning = try JSONDecoder().decode(FocusTuning.self, from: Data(#"{"minimumLead": 1.6, "revealsHidden": false}"#.utf8))
        #expect(tuning.minimumLead == 1.6 && !tuning.revealsHidden)
        #expect(tuning.switchLead == FocusTuning().switchLead && tuning.outlinesBuried)
        let roundTrip = try JSONDecoder().decode(FocusTuning.self, from: JSONEncoder().encode(tuning))
        #expect(roundTrip == tuning)
    }

    @Test func desktopPicksNothing() {
        let target = WindowTargeting.target(gaze: CGPoint(x: 1300, y: 500), sigma: 40, windows: [editor], displays: [screen])
        #expect(target == .none)
    }
}

struct WindowOverviewTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

    func window(_ id: UInt32, _ frame: CGRect) -> ScreenWindow {
        ScreenWindow(id: id, pid: Int32(id), frame: frame, appName: "App \(id)")
    }

    @Test func tilesDontOverlapAndStayOnTheDisplay() {
        // Stacked windows of many shapes, all covering each other.
        let windows = (0..<7).map { (i: Int) -> ScreenWindow in
            let size = CGSize(width: 600 + 80 * (i % 3), height: 500 + 60 * (i % 2))
            return window(UInt32(i), CGRect(origin: CGPoint(x: 40 * i, y: 30 * i), size: size))
        }
        let tiles = WindowOverview.layout(windows, in: screen)
        #expect(tiles.count == windows.count)
        for (i, tile) in tiles.enumerated() {
            #expect(screen.contains(tile))
            // Keeps the window's shape.
            let tileAspect = tile.width / tile.height, windowAspect = windows[i].frame.width / windows[i].frame.height
            #expect(abs(tileAspect - windowAspect) < 0.01)
            for other in tiles[(i + 1)...] { #expect(!tile.intersects(other)) }
        }
        // Big enough to pick by gaze: at least a few centimeters.
        #expect(tiles.allSatisfy { min($0.width, $0.height) > 150 })
    }

    @Test func tilesComeInAFixedOrder() {
        func named(_ id: UInt32, _ app: String, pid: Int32, at x: CGFloat) -> ScreenWindow {
            ScreenWindow(id: id, pid: pid, frame: CGRect(x: x, y: 0, width: 700, height: 900), appName: app)
        }
        let safari2 = named(9, "Safari", pid: 3, at: 0), safari1 = named(4, "Safari", pid: 3, at: 300)
        let mail = named(7, "Mail", pid: 2, at: 800), arc = named(5, "arc", pid: 1, at: 500)
        // By app name (ignoring case), then window by window as opened, wherever they sit or
        // whichever was used last.
        let expected = [arc, mail, safari1, safari2]
        #expect(WindowOverview.ordered([safari2, mail, safari1, arc]) == expected)
        #expect(WindowOverview.ordered([mail, arc, safari2, safari1]) == expected)
        // Laid out in reading order.
        let tiles = WindowOverview.layout(expected, in: screen)
        let reading = tiles.indices.sorted { a, b in
            abs(tiles[a].midY - tiles[b].midY) > 1 ? tiles[a].midY > tiles[b].midY : tiles[a].midX < tiles[b].midX
        }
        #expect(reading == Array(tiles.indices))
    }

    @Test func groupsWindowsByTheirDisplay() {
        let a = window(1, CGRect(x: 100, y: 100, width: 800, height: 600))
        let b = window(2, CGRect(x: 1400, y: 100, width: 1200, height: 800)) // mostly on the external
        let groups = WindowOverview.byDisplay([a, b], displays: [screen, external])
        #expect(groups == [[a], [b]])
    }

    @Test func pickIsForgivingAndSteady() {
        let tiles = [CGRect(x: 100, y: 300, width: 500, height: 400), CGRect(x: 650, y: 300, width: 500, height: 400)]
        func pick(_ x: Double, _ y: Double, sigma: Double = 60, current: Int?) -> Int? {
            WindowOverview.pick(gaze: CGPoint(x: x, y: y), sigma: sigma, tiles: tiles, current: current)
        }
        #expect(pick(350, 500, current: nil) == 0)
        // Just past a tile's edge, or in the gap: the nearest tile.
        #expect(pick(350, 760, current: nil) == 0)
        #expect(pick(640, 500, current: nil) == 1)
        // In the gap, slightly nearer the second tile: keeps the first.
        #expect(pick(630, 500, current: 0) == 0)
        // Inside the second: switches, however close to the edge.
        #expect(pick(655, 500, current: 0) == 1)
        // Far from every tile: nothing.
        #expect(pick(1400, 900, sigma: 30, current: 1) == nil)
    }
}

struct PointerJumpTests {
    @Test func jumpsWhenMovingTowardTheGaze() {
        #expect(PointerJump.shouldJump(from: .zero, to: CGPoint(x: 12, y: 3), gaze: CGPoint(x: 800, y: 100), minimumDistance: 300))
    }

    @Test func staysForMovesAwayOrShortReaches() {
        #expect(!PointerJump.shouldJump(from: .zero, to: CGPoint(x: -12, y: 0), gaze: CGPoint(x: 800, y: 0), minimumDistance: 300))
        #expect(!PointerJump.shouldJump(from: .zero, to: CGPoint(x: 12, y: 0), gaze: CGPoint(x: 200, y: 0), minimumDistance: 300))
        #expect(!PointerJump.shouldJump(from: .zero, to: CGPoint(x: 4, y: 0), gaze: CGPoint(x: 800, y: 0), minimumDistance: 300))
    }
}

struct HiddenWindowTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let big = ScreenWindow(id: 1, pid: 10, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), appName: "Editor")
    let small = ScreenWindow(id: 2, pid: 20, frame: CGRect(x: 500, y: 300, width: 500, height: 400), appName: "Notes")

    @Test func lookingAtTheFocusedWindowRevealsWhatItHides() {
        // The big window was raised over the small one; looking where the small one was brings it back.
        let target = WindowTargeting.target(gaze: CGPoint(x: 750, y: 500), sigma: 50, windows: [big, small], displays: [screen], focused: big.id)
        #expect(target == .window(small))
    }

    @Test func togglesBackToTheBigWindow() {
        let target = WindowTargeting.target(gaze: CGPoint(x: 750, y: 500), sigma: 50, windows: [small, big], displays: [screen], focused: small.id)
        #expect(target == .window(big))
    }

    @Test func nothingHiddenKeepsTheFocusedWindow() {
        let target = WindowTargeting.target(gaze: CGPoint(x: 150, y: 150), sigma: 50, windows: [big, small], displays: [screen], focused: big.id)
        #expect(target == .window(big))
    }

    @Test func unfocusedWindowsArePickedDirectly() {
        let target = WindowTargeting.target(gaze: CGPoint(x: 750, y: 500), sigma: 50, windows: [big, small], displays: [screen], focused: nil)
        #expect(target == .window(big))
    }
}

struct DisplaySwitchingTests {
    let laptop = DisplayInfo(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), millimetersPerPoint: 0.23, vendor: 1, model: 1, serial: 1, name: "Built-in", isBuiltin: true)
    let monitor = DisplayInfo(displayID: 2, frame: CGRect(x: -300, y: 982, width: 2560, height: 1440), millimetersPerPoint: 0.23, vendor: 2, model: 2, serial: 2, name: "External")
    var displays: [DisplayInfo] { [laptop, monitor] }

    /// Feeds the gaze at 15 Hz for `duration` seconds from `start`; returns the first switch.
    func run(_ dwell: inout DisplayDwell, gaze: CGPoint?, from start: Double, duration: Double, current: UInt32 = 1) -> (display: UInt32, at: Double)? {
        var t = start
        while t < start + duration {
            if let display = dwell.update(gaze: gaze, at: t, current: current, displays: displays, sigma: 40) { return (display, t) }
            t += 1.0 / 15
        }
        return nil
    }

    @Test func switchesAfterRestingOnTheOtherDisplay() throws {
        var dwell = DisplayDwell(delay: 0.35)
        let result = try #require(run(&dwell, gaze: CGPoint(x: 900, y: 1700), from: 0, duration: 1))
        #expect(result.display == 2)
        #expect(result.at >= 0.35 && result.at < 0.5)
    }

    @Test func ignoresAGlanceAndTheBezel() {
        var dwell = DisplayDwell(delay: 0.35)
        // A quick glance, then back.
        #expect(run(&dwell, gaze: CGPoint(x: 900, y: 1700), from: 0, duration: 0.25) == nil)
        #expect(run(&dwell, gaze: CGPoint(x: 700, y: 500), from: 0.25, duration: 0.5) == nil)
        // Resting just past the border, within the tracking error.
        #expect(run(&dwell, gaze: CGPoint(x: 900, y: 1030), from: 1, duration: 2) == nil)
        // Already the focused display.
        #expect(run(&dwell, gaze: CGPoint(x: 900, y: 1700), from: 3, duration: 2, current: 2) == nil)
    }

    @Test func blinksDontRestartTheWaitAndSwitchesCoolDown() throws {
        var dwell = DisplayDwell(delay: 0.35)
        let other = CGPoint(x: 900, y: 1700)
        // A blink at 0.1 s: the wait still ends 0.35 s after it began.
        for (t, gaze) in [(0.0, other), (0.1, nil), (0.2, other), (0.3, other)] as [(Double, CGPoint?)] {
            #expect(dwell.update(gaze: gaze, at: t, current: 1, displays: displays, sigma: 40) == nil)
        }
        #expect(dwell.update(gaze: other, at: 0.4, current: 1, displays: displays, sigma: 40) == 2)
        // Straight back to the laptop: waits out the cooldown.
        let back = try #require(run(&dwell, gaze: CGPoint(x: 700, y: 500), from: 0.5, duration: 2, current: 2))
        #expect(back.display == 1 && back.at >= 1.4)
    }

    @Test func remembersTheLastWindowPerDisplay() {
        var memory = DisplayMemory()
        let editor = ScreenWindow(id: 10, pid: 1, frame: CGRect(x: -200, y: 1100, width: 1200, height: 900), appName: "Editor")
        let browser = ScreenWindow(id: 11, pid: 2, frame: CGRect(x: 1000, y: 1100, width: 1200, height: 900), appName: "Browser")
        let notes = ScreenWindow(id: 12, pid: 3, frame: CGRect(x: 100, y: 100, width: 800, height: 600), appName: "Notes")
        // Nothing remembered yet: the frontmost window there.
        #expect(memory.window(on: 2, windows: [notes, browser, editor], displays: displays)?.id == 11)
        memory.record(focused: editor, displays: displays)
        memory.record(focused: notes, displays: displays)
        #expect(memory.window(on: 2, windows: [notes, browser, editor], displays: displays)?.id == 10)
        #expect(memory.window(on: 1, windows: [notes, browser, editor], displays: displays)?.id == 12)
        // Closed since: the frontmost one again.
        #expect(memory.window(on: 2, windows: [notes, browser], displays: displays)?.id == 11)
    }

    @Test func tuningDecodesSettingsWithoutDisplaySwitching() throws {
        let tuning = try JSONDecoder().decode(FocusTuning.self, from: Data(#"{"blurScale": 0.8}"#.utf8))
        #expect(tuning.blurScale == 0.8)
        #expect(!tuning.switchesDisplays)
        #expect(tuning.displayDwell == FocusTuning().displayDwell)
    }
}
