import CoreGraphics
import Foundation
import simd

/// A display as a physical rectangle in camera space.
public struct DisplayPlane: Sendable, Codable, Equatable {
    public var displayID: UInt32
    /// Frame in global AppKit coordinates (points).
    public var frame: CGRect
    /// Physical width and height in millimeters.
    public var size: SIMD2<Double>
    /// Top-left corner as the user sees it, in camera millimeters.
    public var origin: Vec3
    /// Unit vector along the top edge, toward the user's right.
    public var xAxis: Vec3
    /// Unit vector along the left edge, downward.
    public var yAxis: Vec3

    var normal: Vec3 { simd_cross(xAxis, yAxis) }
    var center: Vec3 { origin + xAxis * (size.x / 2) + yAxis * (size.y / 2) }

    /// Where a ray hits the plane, in millimeters from the top-left corner. `nil` if it points away.
    public func intersect(origin o: Vec3, direction g: Vec3) -> SIMD2<Double>? {
        let n = normal
        let denominator = simd_dot(g, n)
        guard abs(denominator) > 1e-9 else { return nil }
        let s = simd_dot(origin - o, n) / denominator
        guard s > 0 else { return nil }
        let offset = o + g * s - origin
        return SIMD2(simd_dot(offset, xAxis), simd_dot(offset, yAxis))
    }

    public func point(fromLocal local: SIMD2<Double>) -> CGPoint {
        CGPoint(
            x: frame.minX + local.x / size.x * frame.width,
            y: frame.maxY - local.y / size.y * frame.height
        )
    }

    public func local(from point: CGPoint) -> SIMD2<Double> {
        SIMD2(
            Double(point.x - frame.minX) / frame.width * size.x,
            Double(frame.maxY - point.y) / frame.height * size.y
        )
    }

    /// Rotated about its center by a rotation vector, then translated.
    func moved(rotation r: Vec3, translation t: Vec3) -> DisplayPlane {
        let m = Rotation.matrix(r)
        var plane = self
        plane.xAxis = m * xAxis
        plane.yAxis = m * yAxis
        plane.origin = center + t - plane.xAxis * (size.x / 2) - plane.yAxis * (size.y / 2)
        return plane
    }
}

/// Per-user calibration: a small affine correction of eye-in-head angles (the eye's visual axis
/// differs from the iris direction by a few degrees, and iris detection has its own bias), plus
/// the physical placement of each display relative to the camera.
public struct GazeModel: Sendable, Codable, Equatable {
    /// `[yaw offset, yaw gain, yaw←pitch, pitch offset, pitch gain, pitch←yaw]`, then optionally
    /// curvature: `[yaw←yaw·pitch, yaw←yaw², yaw←pitch², pitch←yaw·pitch, pitch←yaw², pitch←pitch²]`.
    public var eye: [Double]
    public var planes: [DisplayPlane]
    /// The camera's horizontal field of view in degrees.
    public var fieldOfView: Double
    /// The user's face shape, learned during calibration. `nil` means the generic face.
    public var face: FaceShape?
    /// Which version of the tracking geometry produced this model. Observations from a different
    /// version aren't comparable, so such a model needs recalibrating. `nil` in the oldest profiles.
    public var geometryVersion: Int?
    /// The display the camera sits on, whose placement is known and never adjusted.
    public var anchorDisplayID: UInt32?
    /// Learned per-display corrections on top of the geometry, once there's enough data to trust them.
    public var corrections: [ResidualCorrection]?
    /// Where eye-in-head angles come from. `nil` (older profiles) means the iris geometry.
    public var source: GazeSource?
    /// The user's correction of the gaze network, learned from its features at calibration.
    public var featureCorrection: FeatureCorrection?
    /// Whether the network's angles average it on the face and its mirror image, which is steadier.
    /// What the network outputs depends on it, so it stays as calibrated. `nil` (older profiles) means no.
    public var networkMirrored: Bool?

    public static let identityEye: [Double] = [0, 1, 0, 0, 1, 0]
    /// The identity with curvature terms. Older profiles have only the six linear ones.
    public static let curvedIdentityEye: [Double] = identityEye + [0, 0, 0, 0, 0, 0]

    public init(eye: [Double] = identityEye, planes: [DisplayPlane], fieldOfView: Double = defaultFieldOfView, face: FaceShape? = nil, anchorDisplayID: UInt32? = nil, source: GazeSource = .iris) {
        self.eye = eye
        self.planes = planes
        self.fieldOfView = fieldOfView
        self.face = face
        self.anchorDisplayID = anchorDisplayID
        self.source = source
        geometryVersion = Self.currentGeometryVersion
        networkMirrored = true
    }

    /// 2: fixed field of view, learned face shape, eyeball centers placed by the eye corners.
    public static let currentGeometryVersion = 2

    public var isCurrentGeometry: Bool { geometryVersion == Self.currentGeometryVersion }

    public var faceShape: FaceShape { face ?? .generic }
    public var gazeSource: GazeSource { source ?? .iris }
    public var averagesMirroredNetwork: Bool { networkMirrored ?? false }

    /// Gaze direction in camera space.
    public func direction(for o: GazeObservation) -> Vec3 {
        let a = o.eyeAngles
        var corrected = SIMD2(
            eye[0] + eye[1] * a.x + eye[2] * a.y,
            eye[3] + eye[4] * a.y + eye[5] * a.x
        )
        if eye.count >= 12 {
            let terms = SIMD3(a.x * a.y, a.x * a.x, a.y * a.y)
            corrected += SIMD2(simd_dot(SIMD3(eye[6], eye[7], eye[8]), terms), simd_dot(SIMD3(eye[9], eye[10], eye[11]), terms))
        }
        return o.headRotation * EyeModel.direction(fromAngles: corrected)
    }

    /// The gaze point in global screen coordinates, on whichever display the ray hits (or passes closest to).
    public func predict(_ o: GazeObservation) -> CGPoint? {
        let g = direction(for: o)
        var best: (plane: DisplayPlane, local: SIMD2<Double>, outside: Double)?
        for plane in planes {
            guard let local = plane.intersect(origin: o.origin, direction: g) else { continue }
            let clamped = simd_clamp(local, .zero, plane.size)
            let outside = simd_length(local - clamped)
            if best == nil || outside < best!.outside {
                best = (plane, local, outside)
            }
        }
        guard let best else { return nil }
        return best.plane.point(fromLocal: corrected(best.local, on: best.plane, observation: o))
    }

    /// Where the gaze lands on `plane`, in millimeters from its top-left corner, including learned corrections.
    public func hit(on plane: DisplayPlane, for o: GazeObservation) -> SIMD2<Double>? {
        plane.intersect(origin: o.origin, direction: direction(for: o)).map { corrected($0, on: plane, observation: o) }
    }

    /// On-screen distance in millimeters between this model's prediction and an interaction's target.
    public func error(for sample: InteractionSample) -> Double? {
        guard let plane = planes.first(where: { $0.displayID == sample.displayID }),
              let hit = hit(on: plane, for: sample.observation)
        else { return nil }
        return simd_length(hit - plane.local(from: sample.target))
    }

    private func corrected(_ local: SIMD2<Double>, on plane: DisplayPlane, observation o: GazeObservation) -> SIMD2<Double> {
        guard let correction = corrections?.first(where: { $0.displayID == plane.displayID }) else { return local }
        return local + correction.correction(for: ResidualCorrection.features(observation: o))
    }

    // MARK: Initial layout

    /// Distance from the camera center down to the top of the display it sits on.
    static let builtInCameraOffset = 6.0
    static let externalCameraOffset = 20.0

    /// The display with the camera (the built-in one, or else the primary display, assuming a webcam
    /// on top of it) is placed exactly; the others are placed by the macOS arrangement as a starting
    /// point for calibration to refine.
    public static func initialPlanes(for displays: [DisplayInfo]) -> (planes: [DisplayPlane], anchor: Int) {
        guard !displays.isEmpty else { return ([], 0) }
        let anchor = displays.firstIndex(where: \.isBuiltin) ?? 0
        let a = displays[anchor]
        let anchorSize = SIMD2(a.frame.width, a.frame.height) * a.millimetersPerPoint
        let offset = a.isBuiltin ? builtInCameraOffset : externalCameraOffset
        // Camera +x is the user's left, so the display's left edge is at +x.
        let xAxis = Vec3(-1, 0, 0), yAxis = Vec3(0, -1, 0)
        let anchorCenter = Vec3(0, -offset - anchorSize.y / 2, 0)

        let planes = displays.map { d in
            let size = SIMD2(d.frame.width, d.frame.height) * d.millimetersPerPoint
            var center = anchorCenter
            if d.displayID != a.displayID {
                // Normalized so ±1 means directly adjacent, whatever the two displays' sizes.
                let dx = (d.frame.midX - a.frame.midX) / ((a.frame.width + d.frame.width) / 2)
                let dy = (d.frame.midY - a.frame.midY) / ((a.frame.height + d.frame.height) / 2)
                center += Vec3(-dx * (anchorSize.x + size.x) / 2, dy * (anchorSize.y + size.y) / 2, 0)
            }
            return DisplayPlane(
                displayID: d.displayID,
                frame: d.frame,
                size: size,
                origin: center - xAxis * (size.x / 2) - yAxis * (size.y / 2),
                xAxis: xAxis,
                yAxis: yAxis
            )
        }
        return (planes, anchor)
    }

    // MARK: Fitting

    /// Learns the user's face shape, then fits the eye correction and the placement of every display
    /// except the camera's own, minimizing on-screen error in millimeters.
    public static func fit(_ samples: [CalibrationSample], displays: [DisplayInfo], source: GazeSource = .iris, fieldOfView: Double = defaultFieldOfView, curvedEye: Bool = true) -> GazeModel? {
        let (planes, anchor) = initialPlanes(for: displays)
        let usable = samples.filter { planes.indices.contains($0.displayIndex) }
        guard Set(usable.map(\.targetIndex)).count >= 4 else { return nil }

        // macOS doesn't report the camera's field of view, and fitting it to gaze data runs away:
        // a wider field of view shrinks the estimated face distance, which damps whatever the head
        // pose gets wrong, so the fit prefers absurd values over the true one. A fixed value (typical,
        // or the user's own) keeps the geometry physical; the eye correction absorbs the small
        // remaining scale error.
        var face = FaceShape.fit(usable.map(\.measurements), fieldOfView: fieldOfView)
        let anchorSamples = usable.filter { $0.displayIndex == anchor }
        // The network sees the whole face and needs no eyeball lever.
        if source == .iris, Set(anchorSamples.map(\.targetIndex)).count >= 4 {
            // The lever between head turns and iris movement, chosen by what best explains the
            // display whose position is known, head-motion targets included.
            func error(_ depth: Double) -> Double {
                var candidate = face
                candidate.eyeballDepth = depth
                let problem = FitProblem(calibration: anchorSamples, fieldOfView: fieldOfView, face: candidate, source: source, planes: planes, free: [])
                return problem.meanError(problem.solve(identityEye))
            }
            let coarse = candidateEyeballDepths.min { error($0) < error($1) } ?? face.eyeballDepth
            face.eyeballDepth = [coarse - 0.5, coarse, coarse + 0.5].min { error($0) < error($1) } ?? coarse
        }

        let free = planes.indices.filter { index in
            index != anchor && usable.contains { $0.displayIndex == index }
        }
        // Eye correction first on the anchor display alone, then everything together.
        // Curvature: near the screen's edges, most at the bottom corners, estimates bend toward the
        // middle (on a recording, 40 mm in the bottom corners for the plain network). Pinning it
        // down needs targets all over the screen, which the moving dot gives.
        let prior: FitProblem.Prior = curvedEye && Set(usable.map(\.targetIndex)).count >= curvatureMinimumTargets ? .curvedCalibration : .calibration
        let anchorProblem = FitProblem(calibration: anchorSamples, fieldOfView: fieldOfView, face: face, source: source, planes: planes, free: [], prior: prior)
        let eye = anchorSamples.isEmpty ? prior.eye : anchorProblem.solve(prior.eye)
        let problem = FitProblem(calibration: usable, fieldOfView: fieldOfView, face: face, source: source, planes: planes, free: free, prior: prior)
        guard !problem.targets.isEmpty else { return nil }
        let initial = eye + [Double](repeating: 0, count: free.count * 6)
        var model = problem.model(problem.solve(initial))
        model.anchorDisplayID = planes[anchor].displayID

        // Personalize the network on what it gets wrong for these targets, then refit with that.
        if source == .network, let correction = featureCorrection(usable, model: model) {
            let corrected = FitProblem(calibration: usable, fieldOfView: fieldOfView, face: face, source: source, correction: correction, planes: planes, free: free, prior: prior)
            model = corrected.model(corrected.solve(initial))
            model.anchorDisplayID = planes[anchor].displayID
            model.featureCorrection = correction
        }
        return model
    }

    /// Distinct calibration targets (fixed dots and moving-dot stretches) needed to fit the eye
    /// correction's curvature: only the moving dot covers the screen well enough.
    static let curvatureMinimumTargets = 30


    /// The network's error on each frame, in its own (pitch, yaw), against the true direction from
    /// the face to the target as placed by `model`, learned from the network's features.
    static func featureCorrection(_ samples: [CalibrationSample], model: GazeModel) -> FeatureCorrection? {
        var features: [[Float]] = [], residuals: [SIMD2<Double>] = [], groups: [Int] = []
        // Frames on one target are nearly alike; ten of each keep the fit quick.
        var perTarget: [Int: [CalibrationSample]] = Dictionary(grouping: samples, by: \.targetIndex)
        perTarget = perTarget.mapValues { frames in
            let step = max(1, frames.count / 10)
            return stride(from: 0, to: frames.count, by: step).map { frames[$0] }
        }
        for sample in perTarget.keys.sorted().flatMap({ perTarget[$0]! }) {
            guard let reading = sample.measurements.networkReading, model.planes.indices.contains(sample.displayIndex) else { continue }
            let plane = model.planes[sample.displayIndex]
            let local = plane.local(from: sample.target)
            let target = plane.origin + plane.xAxis * local.x + plane.yAxis * local.y
            let truth = reading.normalization.angles(of: target - reading.normalization.center)
            features.append(reading.features)
            residuals.append(truth - reading.angles)
            groups.append(sample.targetIndex)
        }
        return FeatureCorrection.fit(features: features, residuals: residuals, groups: groups)?.correction
    }

    /// Everyday events with network features needed before the personalization is relearned from them.
    public static let personalizationMinimumEvents = 40
    /// Most recent everyday events the personalization learns from (the fit grows with the cube).
    static let personalizationMaximumEvents = 600

    /// Relearns the network's personalization from learning samples: every calibration event plus
    /// the most recent everyday ones, one row per event (its averaged features, and the network's
    /// error against the true direction to the target as placed by `planes`). `nil` with too few
    /// everyday events.
    static func featureCorrection(_ samples: [InteractionSample], planes: [DisplayPlane]) -> FeatureCorrection? {
        let planeIndex = Dictionary(planes.enumerated().map { ($1.displayID, $0) }, uniquingKeysWith: { a, _ in a })
        let features = samples.featuresByEvent
        struct Row {
            var features: [Float]
            var residual: SIMD2<Double>
            var date: Date
            var isCalibration: Bool
        }
        var rows: [Row] = []
        for (event, frames) in Dictionary(grouping: samples, by: \.event) {
            guard let eventFeatures = features[event], let first = frames.first, let index = planeIndex[first.displayID] else { continue }
            let plane = planes[index]
            // Each frame's own target: in a stretch of following a moving dot, they differ.
            let residuals = frames.compactMap { frame in
                frame.network.map { network in
                    let local = plane.local(from: frame.target)
                    let target = plane.origin + plane.xAxis * local.x + plane.yAxis * local.y
                    return network.normalization.angles(of: target - network.normalization.center) - network.angles
                }
            }
            guard !residuals.isEmpty else { continue }
            rows.append(Row(
                features: eventFeatures,
                residual: residuals.reduce(.zero, +) / Double(residuals.count),
                date: first.date,
                isCalibration: first.source == .calibration
            ))
        }
        let everyday = rows.filter { !$0.isCalibration }.sorted { $0.date < $1.date }.suffix(personalizationMaximumEvents)
        guard everyday.count >= personalizationMinimumEvents else { return nil }
        let used = rows.filter(\.isCalibration) + everyday
        // Regularization is chosen holding out blocks of events rather than one at a time, which
        // would mean hundreds of fits.
        let folds = 5
        return FeatureCorrection.fit(
            features: used.map(\.features),
            residuals: used.map(\.residual),
            groups: used.indices.map { $0 % folds }
        )?.correction
    }

    /// Refines `base` (the explicit calibration) with learning samples: the calibration frames
    /// themselves plus everyday clicks and typing.
    ///
    /// Each frame is weighted by how much its source is trusted, how recent it is (half-life
    /// `recencyHalfLife` seconds), and how crowded its screen region is, so frequently clicked spots
    /// don't dominate. The geometric fit is robust to outliers and pulled toward `base` with the weight
    /// of about `priorStrength` events. With enough everyday data on a display, a learned correction
    /// layer is added on top, kept only if it beats the geometry on held-out recent interactions.
    ///
    /// With `personalize`, the network's personalization is relearned from the samples too (see
    /// `featureCorrection(_:planes:)`) instead of kept from the calibration.
    public static func adapt(
        _ base: GazeModel,
        to samples: [InteractionSample],
        now: Date = .now,
        recencyHalfLife: TimeInterval = 7 * 86400,
        priorStrength: Double = 5,
        personalize: Bool = false
    ) -> GazeModel? {
        let planeIndex = Dictionary(base.planes.enumerated().map { ($1.displayID, $0) }, uniquingKeysWith: { a, _ in a })
        var usable = samples.filter { planeIndex[$0.displayID] != nil }
        guard Set(usable.map(\.event)).count >= 8 else { return nil }

        var featureCorrection = base.featureCorrection
        if base.gazeSource == .network {
            if personalize, let relearned = Self.featureCorrection(usable, planes: base.planes) {
                featureCorrection = relearned
            }
            // Frames were observed with whatever personalization was live at the time.
            usable = usable.rebased(to: featureCorrection)
        }

        let weights = learningWeights(usable, planes: base.planes, planeIndex: planeIndex, now: now, halfLife: recencyHalfLife)
        let eventsPerDisplay = Dictionary(grouping: usable, by: \.displayID).mapValues { Set($0.map(\.event)).count }
        let free = base.planes.indices.filter { index in
            let id = base.planes[index].displayID
            return id != base.anchorDisplayID && eventsPerDisplay[id, default: 0] >= 8
        }
        let k = priorStrength.squareRoot()
        var problem = FitProblem(
            observations: usable.map(\.observation),
            targets: usable.map { base.planes[planeIndex[$0.displayID]!].local(from: $0.target) },
            displayIndices: usable.map { planeIndex[$0.displayID]! },
            weights: weights,
            planes: base.planes,
            free: free,
            fieldOfView: base.fieldOfView,
            face: base.face,
            source: base.gazeSource,
            anchorDisplayID: base.anchorDisplayID,
            // In millimeters on screen per unit of each parameter, at a typical viewing distance.
            prior: .init(
                eye: base.eye,
                eyeWeights: ([600, 150, 150, 600, 150, 150] + (base.eye.count >= 12 ? [Double](repeating: 150, count: 6) : [])).map { $0 * k },
                planeRotationWeight: 200 * k,
                planeTranslationWeight: k
            )
        )
        var model = problem.model(problem.solveRobust(base.eye + [Double](repeating: 0, count: free.count * 6)))
        model.featureCorrection = featureCorrection
        model.networkMirrored = base.networkMirrored
        let corrections = model.planes.compactMap { plane in
            fitCorrection(for: plane, model: model, samples: usable, weights: weights)
        }
        model.corrections = corrections.isEmpty ? nil : corrections
        return model
    }

    /// Per-frame weights: source trust × recency × spatial balance, with each event's frames
    /// sharing that event's weight.
    static func learningWeights(
        _ samples: [InteractionSample],
        planes: [DisplayPlane],
        planeIndex: [UInt32: Int],
        now: Date,
        halfLife: TimeInterval
    ) -> [Double] {
        let framesPerEvent = Dictionary(grouping: samples, by: \.event).mapValues(\.count)

        // Events per cell of a 4×4 grid on each display.
        func cell(_ s: InteractionSample) -> [Int] {
            let plane = planes[planeIndex[s.displayID]!]
            let f = plane.local(from: s.target) / plane.size
            return [Int(s.displayID), min(3, max(0, Int(f.x * 4))), min(3, max(0, Int(f.y * 4)))]
        }
        var eventsPerCell: [[Int]: Set<UUID>] = [:]
        for s in samples {
            eventsPerCell[cell(s), default: []].insert(s.event)
        }
        let meanEventsPerCell = Double(eventsPerCell.values.reduce(0) { $0 + $1.count }) / Double(max(eventsPerCell.count, 1))

        return samples.map { s in
            let age = max(0, now.timeIntervalSince(s.date))
            let recency = pow(0.5, age / (halfLife * s.source.halfLifeMultiplier))
            let crowding = Double(eventsPerCell[cell(s)]?.count ?? 1)
            let balance = min(2, max(0.25, (meanEventsPerCell / crowding).squareRoot()))
            return s.source.weight / Double(framesPerEvent[s.event] ?? 1) * recency * balance
        }
    }

    /// Minimum everyday (non-calibration) events on a display before a correction layer is tried.
    static let correctionMinimumEvents = 60

    /// Fits a correction layer for one display on what `model` still gets wrong, choosing its
    /// smoothness on the most recent interactions held out; `nil` unless it clearly helps there.
    static func fitCorrection(
        for plane: DisplayPlane,
        model: GazeModel,
        samples: [InteractionSample],
        weights: [Double]
    ) -> ResidualCorrection? {
        struct Point {
            var features: [Double]
            var residual: SIMD2<Double>
            var weight: Double
            var date: Date
            var event: UUID
        }

        let indices = samples.indices.filter { samples[$0].displayID == plane.displayID }
        let everydayEvents = Set(indices.filter { samples[$0].source != .calibration }.map { samples[$0].event })
        guard everydayEvents.count >= correctionMinimumEvents else { return nil }

        // At most 3 frames per event keeps the kernel small without losing coverage.
        var perEvent: [UUID: Int] = [:]
        var points: [Point] = []
        for i in indices {
            let s = samples[i]
            guard perEvent[s.event, default: 0] < 3,
                  let hit = plane.intersect(origin: s.observation.origin, direction: model.direction(for: s.observation))
            else { continue }
            perEvent[s.event, default: 0] += 1
            points.append(Point(
                features: ResidualCorrection.features(observation: s.observation),
                residual: plane.local(from: s.target) - hit,
                weight: weights[i],
                date: s.date,
                event: s.event
            ))
        }
        // Drop gross outliers, then keep the newest points.
        let typical = median(points.map { simd_length($0.residual) })
        points = points.filter { simd_length($0.residual) < max(3 * typical, 30) }
        points = Array(points.sorted { $0.date < $1.date }.suffix(450))

        // Hold out the newest 20% of everyday events to choose settings and check it helps.
        let heldOutEvents = Set(points.filter { everydayEvents.contains($0.event) }
            .sorted { $0.date < $1.date }
            .map(\.event)
            .reversed()
            .prefix(max(10, everydayEvents.count / 5)))
        let train = points.filter { !heldOutEvents.contains($0.event) }
        let test = points.filter { heldOutEvents.contains($0.event) }
        guard train.count >= 40, test.count >= 10 else { return nil }

        func fit(_ data: [Point], bandwidth: Double, lambda: Double) -> ResidualCorrection? {
            ResidualCorrection.fit(
                displayID: plane.displayID,
                features: data.map(\.features),
                residuals: data.map(\.residual),
                weights: data.map(\.weight),
                bandwidth: bandwidth,
                lambda: lambda
            )
        }
        func testError(_ correction: ResidualCorrection?) -> Double {
            median(test.map { p in simd_length(p.residual - (correction?.correction(for: p.features) ?? .zero)) })
        }

        let baseline = testError(nil)
        var best: (bandwidth: Double, lambda: Double, error: Double)?
        for bandwidth in [0.7, 1.2, 2.0] {
            for lambda in [0.1, 0.5, 2.0] {
                guard let candidate = fit(train, bandwidth: bandwidth, lambda: lambda) else { continue }
                let error = testError(candidate)
                if best == nil || error < best!.error {
                    best = (bandwidth, lambda, error)
                }
            }
        }
        guard let best, best.error < baseline * 0.95 else { return nil }
        return fit(points, bandwidth: best.bandwidth, lambda: best.lambda)
    }

    /// Typical of Mac cameras (horizontal, 16:9) and most webcams.
    public static let defaultFieldOfView = 70.0
    /// Field of view values a user may enter, in degrees.
    public static let fieldOfViewRange = 40.0...130.0
    /// Anatomically about 6 mm; the range is wide because it also absorbs the head pose's error
    /// in how far the head turned.
    static let candidateEyeballDepths = Array(stride(from: 0.0, through: 16.0, by: 1.0))
}

/// Calibration as a least-squares problem over `[eye correction (6)] + [rotation, translation (6)]`
/// per display being placed.
private struct FitProblem {
    /// Pulls parameters toward known values when the data can't pin them down.
    struct Prior {
        var eye: [Double]
        var eyeWeights: [Double]
        var planeRotationWeight: Double
        var planeTranslationWeight: Double

        /// Weak: the eye correction should be near identity, displays near the macOS arrangement.
        static let calibration = Prior(eye: GazeModel.identityEye, eyeWeights: [0, 20, 20, 0, 20, 20], planeRotationWeight: 200, planeTranslationWeight: 0.05)
        /// With curvature, kept small unless the data clearly asks for it.
        static let curvedCalibration = Prior(eye: GazeModel.curvedIdentityEye, eyeWeights: [0, 20, 20, 0, 20, 20] + [Double](repeating: 30, count: 6), planeRotationWeight: 200, planeTranslationWeight: 0.05)
    }

    /// Eye correction parameters: 6 linear, or 12 with curvature.
    var eyeCount: Int { prior.eye.count }

    var observations: [GazeObservation]
    var targets: [SIMD2<Double>]
    var displayIndices: [Int]
    var weights: [Double]
    var planes: [DisplayPlane]
    var free: [Int]
    var fieldOfView: Double
    var face: FaceShape?
    var source: GazeSource
    var anchorDisplayID: UInt32?
    var prior: Prior

    init(
        observations: [GazeObservation],
        targets: [SIMD2<Double>],
        displayIndices: [Int],
        weights: [Double],
        planes: [DisplayPlane],
        free: [Int],
        fieldOfView: Double,
        face: FaceShape?,
        source: GazeSource,
        anchorDisplayID: UInt32?,
        prior: Prior
    ) {
        self.observations = observations
        self.targets = targets
        self.displayIndices = displayIndices
        self.weights = weights
        self.planes = planes
        self.free = free
        self.fieldOfView = fieldOfView
        self.face = face
        self.source = source
        self.anchorDisplayID = anchorDisplayID
        self.prior = prior
    }

    /// Redoes each sample's 3D estimate with `fieldOfView` and `face`.
    init(calibration samples: [CalibrationSample], fieldOfView: Double, face: FaceShape, source: GazeSource, correction: FeatureCorrection? = nil, planes: [DisplayPlane], free: [Int], prior: Prior = .calibration) {
        let estimator = HeadPoseEstimator(face: face)
        var observations: [GazeObservation] = []
        var targets: [SIMD2<Double>] = []
        var displayIndices: [Int] = []
        for sample in samples {
            guard let (_, observation) = sample.measurements.observe(fieldOfView: fieldOfView, face: face, source: source, correction: correction, using: estimator) else { continue }
            observations.append(observation)
            targets.append(planes[sample.displayIndex].local(from: sample.target))
            displayIndices.append(sample.displayIndex)
        }
        self.init(
            observations: observations,
            targets: targets,
            displayIndices: displayIndices,
            weights: [Double](repeating: 1, count: observations.count),
            planes: planes,
            free: free,
            fieldOfView: fieldOfView,
            face: face,
            source: source,
            anchorDisplayID: nil,
            prior: prior
        )
    }

    func model(_ p: [Double]) -> GazeModel {
        var placed = planes
        for (k, index) in free.enumerated() {
            let base = eyeCount + k * 6
            placed[index] = planes[index].moved(
                rotation: Vec3(p[base], p[base + 1], p[base + 2]),
                translation: Vec3(p[base + 3], p[base + 4], p[base + 5])
            )
        }
        return GazeModel(eye: Array(p[0..<eyeCount]), planes: placed, fieldOfView: fieldOfView, face: face, anchorDisplayID: anchorDisplayID, source: source)
    }

    /// Per-sample on-screen error vectors in millimeters.
    func errors(_ p: [Double]) -> [SIMD2<Double>] {
        let m = model(p)
        return observations.indices.map { i in
            let o = observations[i]
            guard let hit = m.planes[displayIndices[i]].intersect(origin: o.origin, direction: m.direction(for: o)) else {
                return SIMD2(1000, 1000)
            }
            return hit - targets[i]
        }
    }

    func meanError(_ p: [Double]) -> Double {
        let e = errors(p)
        return e.isEmpty ? .infinity : e.reduce(0) { $0 + simd_length($1) } / Double(e.count)
    }

    func solve(_ initial: [Double]) -> [Double] {
        let steps = [Double](repeating: 1e-4, count: eyeCount)
            + Array(repeating: [1e-4, 1e-4, 1e-4, 1e-2, 1e-2, 1e-2], count: free.count).flatMap { $0 }
        let sqrtWeights = weights.map { $0.squareRoot() }
        return LeastSquares.minimize(initial, steps: steps, iterations: 60) { p in
            var r: [Double] = []
            r.reserveCapacity(observations.count * 2 + eyeCount + free.count * 6)
            for (e, w) in zip(errors(p), sqrtWeights) {
                r.append(e.x * w)
                r.append(e.y * w)
            }
            r += (0..<eyeCount).map { prior.eyeWeights[$0] * (p[$0] - prior.eye[$0]) }
            for k in free.indices {
                let base = eyeCount + k * 6
                r += (0..<3).map { prior.planeRotationWeight * p[base + $0] }
                r += (3..<6).map { prior.planeTranslationWeight * p[base + $0] }
            }
            return r
        }
    }

    /// Iteratively reweighted least squares with a Huber loss: samples off by more than `huber`
    /// millimeters count proportionally less, so the occasional click made without looking at the
    /// cursor doesn't skew the fit.
    mutating func solveRobust(_ initial: [Double], rounds: Int = 3, huber: Double = 25) -> [Double] {
        let base = weights
        var p = solve(initial)
        for _ in 1..<rounds {
            weights = zip(base, errors(p)).map { w, e in w * min(1, huber / max(simd_length(e), 1e-9)) }
            p = solve(p)
        }
        weights = base
        return p
    }
}

/// One frame collected while the user looked at a calibration target.
public struct CalibrationSample: Sendable, Equatable {
    public var measurements: FaceMeasurements
    /// Target position in global AppKit screen coordinates.
    public var target: CGPoint
    /// Frames looking at the same target share an index.
    public var targetIndex: Int
    /// Index into the display list the calibration ran with.
    public var displayIndex: Int

    public init(measurements: FaceMeasurements, target: CGPoint, targetIndex: Int, displayIndex: Int) {
        self.measurements = measurements
        self.target = target
        self.targetIndex = targetIndex
        self.displayIndex = displayIndex
    }
}
