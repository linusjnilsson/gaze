import CoreGraphics
import CoreVideo
import Foundation
import GazeKit
import ImageIO
import simd

/// Replays a calibration recording offline: fits each gaze source on the calibration targets and
/// reports accuracy per axis on the held-out validation targets.
///
///     swift run -c release gaze-eval [recording directory]   (default: the newest recording)

struct Session: Decodable {
    var displays: [DisplayInfo]
    var frames: [Frame]
}

struct Frame: Decodable {
    var timestamp: TimeInterval
    var targetIndex: Int
    var target: CGPoint
    var displayIndex: Int
    var moveHead: Bool
    var imageSize: SIMD2<Double>
    var landmarks: [SIMD2<Double>?]
    var irisImageLeft: SIMD2<Double>
    var irisImageRight: SIMD2<Double>
    var networkGaze: SIMD3<Double>?
    var file: String?
    var crop: CGRect?

    var measurements: FaceMeasurements {
        FaceMeasurements(timestamp: timestamp, imageSize: imageSize, landmarks: landmarks, irisImageLeft: irisImageLeft, irisImageRight: irisImageRight, networkGaze: networkGaze)
    }
}

let recordings = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Gaze/Recordings")
let url = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
    ?? (try! FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil)).filter(\.hasDirectoryPath).max { $0.lastPathComponent < $1.lastPathComponent }!
var session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: url.appendingPathComponent("session.json")))
print("Recording \(url.lastPathComponent): \(session.frames.count) frames, \(session.displays.count) display(s)")

// The app shows 12 calibration targets per display, then the validation targets. Stretches of
// following the moving dot are numbered from 10000 (the sweep) and 20000 (the loops), and of
// holding a dot while turning the head from 30000; they count as calibration; `-nopursuit` leaves them out, to compare.
let calibrationCount = 12 * session.displays.count
let pursuitBase = 10_000
if CommandLine.arguments.contains("-nopursuit") {
    session.frames.removeAll { $0.targetIndex >= pursuitBase }
}
// `-firstpass`: without the second moving-dot pass (the loops, in another posture), numbered from 20000.
if CommandLine.arguments.contains("-firstpass") {
    session.frames.removeAll { (20_000..<30_000).contains($0.targetIndex) }
}
// `-noheadpass`: without the stretches of holding a dot while turning the head, numbered from 30000.
if CommandLine.arguments.contains("-noheadpass") {
    session.frames.removeAll { $0.targetIndex >= 30_000 }
}
// `-pursuit <fraction>`: keep that share of the moving dot (in blocks of three neighboring
// stretches, spread over the whole path), to see how accuracy grows with more of it.
if let flag = CommandLine.arguments.firstIndex(of: "-pursuit"), let fraction = Double(CommandLine.arguments[flag + 1]) {
    session.frames.removeAll { (pursuitBase..<30_000).contains($0.targetIndex) && Double(((($0.targetIndex - pursuitBase) / 3) * 7) % 12) >= fraction * 12 }
}
let pursuitCount = Set(session.frames.map(\.targetIndex).filter { $0 >= pursuitBase }).count
if pursuitCount > 0 { print("Moving dot: \(pursuitCount) stretches, \(session.frames.filter { $0.targetIndex >= pursuitBase }.count) frames") }
func isCalibration(_ index: Int) -> Bool { index < calibrationCount || index >= pursuitBase }
var validation = session.frames.filter { !isCalibration($0.targetIndex) }
func samples(_ frames: [Frame]) -> [CalibrationSample] {
    frames.filter { isCalibration($0.targetIndex) }.map {
        CalibrationSample(measurements: $0.measurements, target: $0.target, targetIndex: $0.targetIndex, displayIndex: $0.displayIndex)
    }
}

/// Per frame of each validation target: the on-screen hit (mm from the top-left, y down).
func hits(_ model: GazeModel) -> [Int: [SIMD2<Double>]] {
    let estimator = HeadPoseEstimator()
    var result: [Int: [SIMD2<Double>]] = [:]
    for frame in validation {
        let plane = model.planes[frame.displayIndex]
        guard let (_, o) = frame.measurements.observe(for: model, using: estimator), let hit = model.hit(on: plane, for: o) else { continue }
        result[frame.targetIndex, default: []].append(hit)
    }
    return result
}

func targetLocal(_ index: Int, _ model: GazeModel) -> SIMD2<Double> {
    let frame = validation.first { $0.targetIndex == index }!
    return model.planes[frame.displayIndex].local(from: frame.target)
}

func std(_ values: [Double]) -> Double {
    let mean = values.reduce(0, +) / Double(values.count)
    return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
}

func report(_ name: String, _ perTarget: [Int: [SIMD2<Double>]], model: GazeModel) {
    var ex: [Double] = [], ey: [Double] = [], nx: [Double] = [], ny: [Double] = []
    var lines: [String] = []
    for index in perTarget.keys.sorted() {
        let frames = perTarget[index]!
        let estimate = SIMD2(median(frames.map(\.x)), median(frames.map(\.y)))
        let error = estimate - targetLocal(index, model)
        ex.append(abs(error.x)); ey.append(abs(error.y))
        let moving = validation.first { $0.targetIndex == index }!.moveHead
        if !moving, frames.count > 3 {
            nx.append(std(frames.map(\.x))); ny.append(std(frames.map(\.y)))
        }
        lines.append(String(format: "    %@ dx %+5.0f dy %+5.0f", moving ? "move " : "still", error.x, error.y))
    }
    let mean = { (v: [Double]) in v.reduce(0, +) / Double(max(v.count, 1)) }
    print(String(format: "%@  error |x| %.0f |y| %.0f mm   frame noise x %.0f y %.0f mm", name.padding(toLength: 16, withPad: " ", startingAt: 0), mean(ex), mean(ey), mean(nx), mean(ny)))
    if CommandLine.arguments.contains("-v") { lines.forEach { print($0) } }
}

/// `-time`: how long the calibration fit takes, with the frames as recorded and with every
/// frame (validation included) as if calibration had that many.
if CommandLine.arguments.contains("-time") {
    // The personalization fit at the size of a calibration with the moving dot.
    var rng = SystemRandomNumberGenerator()
    for (rows, groupCount) in [(190, 19), (500, 50), (700, 70), (1500, 118), (3000, 236)] {
        let features = (0..<rows).map { _ in (0..<512).map { _ in Float.random(in: -1...1, using: &rng) } }
        let residuals = (0..<rows).map { _ in SIMD2(Double.random(in: -0.1...0.1), .random(in: -0.1...0.1)) }
        let start = Date()
        _ = FeatureCorrection.fit(features: features, residuals: residuals, groups: (0..<rows).map { $0 * groupCount / rows })
        print(String(format: "personalization, %d frames in %d groups: %.2f s", rows, groupCount, Date().timeIntervalSince(start)))
    }
    let all = session.frames.map { CalibrationSample(measurements: $0.measurements, target: $0.target, targetIndex: $0.targetIndex, displayIndex: $0.displayIndex) }
    for (name, set) in [("calibration", samples(session.frames)), ("all frames", all), ("all frames x2", all + all.map { var s = $0; s.targetIndex += 20_000; return s })] {
        for source in GazeSource.allCases {
            let start = Date()
            _ = GazeModel.fit(set, displays: session.displays, source: source)
            print(String(format: "%@ (%d frames) %@: %.2f s", name, set.count, source.rawValue, Date().timeIntervalSince(start)))
        }
    }
    exit(0)
}

var models: [GazeSource: GazeModel] = [:]
for source in GazeSource.allCases {
    guard let model = GazeModel.fit(samples(session.frames), displays: session.displays, source: source) else { continue }
    models[source] = model
    print("\(source): eye \(model.eye.map { String(format: "%.3f", $0) }.joined(separator: " "))")
    report(source.rawValue, hits(model), model: model)
}

// Blending the two calibrated predictions per frame, per axis.
if let iris = models[.iris], let network = models[.network] {
    let a = hits(iris), b = hits(network)
    for (wx, wy) in [(1.0, 0.75), (1.0, 0.5), (0.75, 0.75), (0.75, 0.5)] {
        var blended: [Int: [SIMD2<Double>]] = [:]
        for (index, hb) in b {
            guard let ha = a[index] else { continue }
            blended[index] = zip(ha, hb).map { SIMD2(wx * $1.x + (1 - wx) * $0.x, wy * $1.y + (1 - wy) * $0.y) }
        }
        report(String(format: "net %.2f/%.2f", wx, wy), blended, model: network)
    }
}

// MARK: Re-running the network on the recorded face crops

guard let modelURL = [URL(fileURLWithPath: "Models/GazeNet.mlpackage")].first(where: { FileManager.default.fileExists(atPath: $0.path) }),
      let network = try? GazeNetwork(url: modelURL),
      let face = models[.network]?.faceShape
else { exit(0) }

func bgra(_ url: URL) -> CVPixelBuffer? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )
    context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buffer
}

let images = session.frames.map { frame in frame.file.flatMap { bgra(url.appendingPathComponent($0)) } }

/// Runs the network on every recorded crop.
func rerun(mirrored: Bool = false, fieldOfView: Double = GazeModel.defaultFieldOfView, face: FaceShape = face) -> [GazeNetwork.Estimate?] {
    network.averagesMirrored = mirrored
    defer { network.averagesMirrored = false }
    let estimator = HeadPoseEstimator(face: face)
    return zip(session.frames, images).map { frame, image in
        var intrinsics = CameraIntrinsics(imageWidth: frame.imageSize.x, imageHeight: frame.imageSize.y, horizontalFOVDegrees: fieldOfView)
        guard let image, let crop = frame.crop,
              let head = estimator.estimate(frame.landmarks, intrinsics: intrinsics, time: frame.timestamp)
        else { return nil }
        intrinsics.center -= SIMD2(crop.minX, crop.minY)
        return network.estimate(in: image, head: head, face: face, intrinsics: intrinsics)
    }
}


func evaluate(_ name: String, _ directions: [Vec3?]) {
    var frames = session.frames
    for i in frames.indices { frames[i].networkGaze = directions[i] }
    validation = frames.filter { !isCalibration($0.targetIndex) }
    guard let model = GazeModel.fit(samples(frames), displays: session.displays, source: .network) else { return }
    report(name, hits(model), model: model)
}

print("\nNetwork re-run on recorded crops:")
let estimates = rerun()
evaluate("plain", estimates.map { $0?.direction })

// Personalize: what the network gets wrong on the calibration dots, learned from its features.
let base = models[.network]!
var features: [[Float]] = [], residuals: [SIMD2<Double>] = [], groups: [Int] = []
for (frame, estimate) in zip(session.frames, estimates) where isCalibration(frame.targetIndex) {
    guard let estimate, let f = estimate.features else { continue }
    let plane = base.planes[frame.displayIndex]
    let local = plane.local(from: frame.target)
    let target3D = plane.origin + plane.xAxis * local.x + plane.yAxis * local.y
    let truth = estimate.normalization.angles(of: target3D - estimate.normalization.center)
    features.append(f)
    residuals.append(truth - estimate.angles)
    groups.append(frame.targetIndex)
}
if let (correction, heldOut, baseline) = FeatureCorrection.fit(features: features, residuals: residuals, groups: groups) {
    print(String(format: "feature correction: held-out target error %.2f° (uncorrected %.2f°)", heldOut * 180 / .pi, baseline * 180 / .pi))
    evaluate("personalized", estimates.map { e in
        e.flatMap { e in e.features.map { e.normalization.gazeDirection(pitch: e.angles.x + correction.correction(for: $0).x, yaw: e.angles.y + correction.correction(for: $0).y) } }
    })
}

// MARK: Leave one target out, over every recorded target

/// Per still target, fitted on all other targets: the held-out target's frames' hits (mm on its
/// display) by frame index, and where the target is.
typealias HeldOut = [Int: (target: SIMD2<Double>, hits: [Int: SIMD2<Double>])]

func leaveOneOut(_ estimates: [GazeNetwork.Estimate?], personalize: Bool, source: GazeSource = .network, fieldOfView: Double = GazeModel.defaultFieldOfView, moving: Bool = false, trainOnMoving: Bool = true, personalizeOnMoving: Bool = true, movingKept: Int = .max) -> HeldOut {
    var result: HeldOut = [:]
    let targets = Set(session.frames.map(\.targetIndex)).sorted()
    for held in targets {
        let heldFrames = session.frames.indices.filter { session.frames[$0].targetIndex == held }
        guard session.frames[heldFrames[0]].moveHead == moving, held < pursuitBase else { continue }
        let keptMoving = Set(targets.filter { t in t != held && session.frames.first { $0.targetIndex == t }!.moveHead }.prefix(movingKept))
        let usable = session.frames.indices.filter { session.frames[$0].targetIndex != held && (!session.frames[$0].moveHead || keptMoving.contains(session.frames[$0].targetIndex)) }
        let train = usable.filter { trainOnMoving || !session.frames[$0].moveHead }
        let personalTrain = usable.filter { personalizeOnMoving || !session.frames[$0].moveHead }
        var directions = estimates.map { $0?.direction }
        if personalize {
            var f: [[Float]] = [], r: [SIMD2<Double>] = [], g: [Int] = []
            for i in personalTrain {
                guard let e = estimates[i], let features = e.features else { continue }
                let frame = session.frames[i], plane = base.planes[frame.displayIndex]
                let local = plane.local(from: frame.target)
                let target3D = plane.origin + plane.xAxis * local.x + plane.yAxis * local.y
                f.append(features)
                r.append(e.normalization.angles(of: target3D - e.normalization.center) - e.angles)
                g.append(frame.targetIndex)
            }
            guard let (correction, _, _) = FeatureCorrection.fit(features: f, residuals: r, groups: g) else { continue }
            directions = estimates.map { e in
                e.flatMap { e in e.features.map { let c = correction.correction(for: $0); return e.normalization.gazeDirection(pitch: e.angles.x + c.x, yaw: e.angles.y + c.y) } }
            }
        }
        let trainSamples = train.compactMap { i -> CalibrationSample? in
            var m = session.frames[i].measurements
            m.networkGaze = directions[i]
            return CalibrationSample(measurements: m, target: session.frames[i].target, targetIndex: session.frames[i].targetIndex, displayIndex: session.frames[i].displayIndex)
        }
        guard let model = GazeModel.fit(trainSamples, displays: session.displays, source: source, fieldOfView: fieldOfView) else { continue }
        let estimator = HeadPoseEstimator()
        let plane = model.planes[session.frames[heldFrames[0]].displayIndex]
        var hits: [Int: SIMD2<Double>] = [:]
        for i in heldFrames {
            var m = session.frames[i].measurements
            m.networkGaze = directions[i]
            if let hit = m.observe(for: model, using: estimator).flatMap({ model.hit(on: plane, for: $0.observation) }) { hits[i] = hit }
        }
        if !hits.isEmpty { result[held] = (plane.local(from: session.frames[heldFrames[0]].target), hits) }
    }
    return result
}

/// Per-frame blend of two held-out predictions, weight `w` (per axis) on `b`.
func blend(_ a: HeldOut, _ b: HeldOut, _ w: SIMD2<Double>) -> HeldOut {
    var result: HeldOut = [:]
    for (index, tb) in b {
        guard let ta = a[index] else { continue }
        let hits = tb.hits.compactMap { i, hb in ta.hits[i].map { (i, (1 - w) * $0 + w * hb) } }
        if !hits.isEmpty { result[index] = (tb.target, Dictionary(uniqueKeysWithValues: hits)) }
    }
    return result
}

func errors(_ heldOut: HeldOut) -> (x: Double, y: Double, count: Int) {
    var ex: [Double] = [], ey: [Double] = []
    for (_, t) in heldOut {
        let hits = Array(t.hits.values)
        ex.append(abs(median(hits.map(\.x)) - t.target.x)); ey.append(abs(median(hits.map(\.y)) - t.target.y))
    }
    return (ex.reduce(0, +) / Double(max(ex.count, 1)), ey.reduce(0, +) / Double(max(ey.count, 1)), ex.count)
}

func printLOO(_ name: String, _ heldOut: HeldOut) {
    let e = errors(heldOut)
    let noise = heldOut.values.filter { $0.hits.count > 3 }.map { t in SIMD2(std(t.hits.values.map(\.x)), std(t.hits.values.map(\.y))) }
    let n = noise.reduce(SIMD2<Double>(), +) / Double(max(noise.count, 1))
    print(String(format: "%@  leave-one-out over %d still targets: |x| %.1f |y| %.1f mm   frame noise x %.1f y %.1f mm", name.padding(toLength: 22, withPad: " ", startingAt: 0), e.count, e.x, e.y, n.x, n.y))
}

/// `-fov`: which camera field of view explains the recording best. For each candidate, the face
/// shape is learned and the network re-run with it, then scored by leaving one still target out.
if CommandLine.arguments.contains("-fov") {
    print("\nField of view sweep (mirrored, personalized network, leave-one-out):")
    for fov in [55.0, 62, 70, 78, 86, 95, 105] {
        guard let shape = GazeModel.fit(samples(session.frames), displays: session.displays, source: .network, fieldOfView: fov)?.faceShape else { continue }
        let heldOut = leaveOneOut(rerun(mirrored: true, fieldOfView: fov, face: shape), personalize: true, fieldOfView: fov)
        let iris = leaveOneOut(rerun(mirrored: true, fieldOfView: fov, face: shape), personalize: false, source: .iris, fieldOfView: fov)
        let e = errors(heldOut), i = errors(iris)
        print(String(format: "  %3.0f°  network |x| %4.1f |y| %4.1f mm   iris |x| %4.1f |y| %4.1f mm", fov, e.x, e.y, i.x, i.y))
    }
    exit(0)
}

/// `-regions`: where on the screen the error is. Fixed still targets and stretches of the moving
/// dot are held out a sixth at a time (neighboring stretches together), fitted on the rest with
/// the personalized mirrored network, and the held-out frames' errors mapped on a 5×5 grid:
/// the signed mean (+x right, +y down, mm) and how much of it points toward the screen center.
/// `-insample` fits and judges on every frame, `-nopersonal` leaves out the personalization, and
/// `-linear` the eye correction's curvature.
if CommandLine.arguments.contains("-regions") {
    let mirrored = rerun(mirrored: true)
    let folds = 6
    func fold(_ index: Int) -> Int { index >= pursuitBase ? ((index - pursuitBase) / 3) % folds : index % folds }
    var held: [(target: SIMD2<Double>, hit: SIMD2<Double>, pursuit: Bool)] = []
    var size = SIMD2<Double>(1, 1)
    for k in 0..<folds {
        // `-insample`: fitted on everything and judged on the same frames, as the live model is.
        let inSample = CommandLine.arguments.contains("-insample")
        if inSample, k > 0 { break }
        let train = session.frames.indices.filter { inSample || fold(session.frames[$0].targetIndex) != k }
        let test = session.frames.indices.filter { i in
            let f = session.frames[i]
            return (inSample || fold(f.targetIndex) == k) && !f.moveHead
        }
        var f: [[Float]] = [], r: [SIMD2<Double>] = [], g: [Int] = []
        for i in train {
            guard let e = mirrored[i], let features = e.features else { continue }
            let frame = session.frames[i], plane = base.planes[frame.displayIndex]
            let local = plane.local(from: frame.target)
            f.append(features)
            r.append(e.normalization.angles(of: plane.origin + plane.xAxis * local.x + plane.yAxis * local.y - e.normalization.center) - e.angles)
            g.append(frame.targetIndex)
        }
        guard let (correction, _, _) = FeatureCorrection.fit(features: f, residuals: r, groups: g) else { continue }
        let personal = !CommandLine.arguments.contains("-nopersonal")
        let directions = mirrored.map { e in
            e.flatMap { e in e.features.map { let c = personal ? correction.correction(for: $0) : .zero; return e.normalization.gazeDirection(pitch: e.angles.x + c.x, yaw: e.angles.y + c.y) } }
        }
        let trainSamples = train.map { i -> CalibrationSample in
            var m = session.frames[i].measurements
            m.networkGaze = directions[i]
            return CalibrationSample(measurements: m, target: session.frames[i].target, targetIndex: session.frames[i].targetIndex, displayIndex: session.frames[i].displayIndex)
        }
        guard let model = GazeModel.fit(trainSamples, displays: session.displays, source: .network, curvedEye: !CommandLine.arguments.contains("-linear")) else { continue }
        if k == 0 { print("eye: \(model.eye.map { String(format: "%.3f", $0) }.joined(separator: " "))") }
        let estimator = HeadPoseEstimator()
        for i in test {
            let frame = session.frames[i], plane = model.planes[frame.displayIndex]
            size = plane.size
            var m = frame.measurements
            m.networkGaze = directions[i]
            // Unclamped: where the ray meets the display's plane, even past its edge.
            guard let o = m.observe(for: model, using: estimator)?.observation, let hit = model.hit(on: plane, for: o) else { continue }
            held.append((plane.local(from: frame.target), hit, frame.targetIndex >= pursuitBase))
        }
    }
    for (name, subset) in [("all held-out frames", held), ("moving dot only", held.filter(\.pursuit)), ("fixed dots only", held.filter { !$0.pursuit })] {
        print("\nError by screen region, \(name) (\(subset.count) frames): mean dx,dy mm | toward center mm | frames")
        for row in 0..<5 {
            var line = ""
            for column in 0..<5 {
                let cell = subset.filter { Int(min(4, max(0, $0.target.x / size.x * 5))) == column && Int(min(4, max(0, $0.target.y / size.y * 5))) == row }
                guard !cell.isEmpty else { line += "            .            "; continue }
                let errors = cell.map { $0.hit - $0.target }
                let mean = errors.reduce(.zero, +) / Double(cell.count)
                let inward = zip(cell, errors).map { c, e in
                    let out = c.target - size / 2
                    return simd_length(out) < 1 ? 0 : -simd_dot(e, simd_normalize(out))
                }.reduce(0, +) / Double(cell.count)
                line += String(format: "%+4.0f,%+4.0f |%+4.0f |%4d   ", mean.x, mean.y, inward, cell.count)
            }
            print(line)
        }
    }
    exit(0)
}

/// `-headpose`: how error grows with head turns. Each head-motion target (and each still one) is
/// held out in turn; frames are binned by how far the head is turned from its median pose during
/// the still targets.
if CommandLine.arguments.contains("-headpose") {
    let mirrored = rerun(mirrored: true)
    let estimator = HeadPoseEstimator(face: face)
    let angles: [Vec3?] = session.frames.map { frame in
        let intrinsics = CameraIntrinsics(imageWidth: frame.imageSize.x, imageHeight: frame.imageSize.y, horizontalFOVDegrees: GazeModel.defaultFieldOfView)
        return estimator.estimate(frame.landmarks, intrinsics: intrinsics, time: frame.timestamp).map { Rotation.headAngles($0.rotation) * 180 / .pi }
    }
    let still = session.frames.indices.filter { !session.frames[$0].moveHead }.compactMap { angles[$0] }
    let rest = Vec3(median(still.map(\.x)), median(still.map(\.y)), 0)
    print(String(format: "head at rest: yaw %+.1f° pitch %+.1f°", rest.x, rest.y))
    func table(_ name: String, _ heldOut: HeldOut) {
        // Per frame: (|Δyaw|, |Δpitch|, error x, error y), signed errors kept for direction.
        var rows: [(dyaw: Double, dpitch: Double, e: SIMD2<Double>)] = []
        for (_, t) in heldOut {
            for (i, hit) in t.hits {
                guard let a = angles[i] else { continue }
                rows.append((a.x - rest.x, a.y - rest.y, hit - t.target))
            }
        }
        let mx = rows.map { abs($0.e.x) }.reduce(0, +) / Double(max(rows.count, 1)), my = rows.map { abs($0.e.y) }.reduce(0, +) / Double(max(rows.count, 1))
        let turned = rows.filter { max(abs($0.dyaw), abs($0.dpitch)) >= 5 }
        let tx = turned.map { abs($0.e.x) }.reduce(0, +) / Double(max(turned.count, 1)), ty = turned.map { abs($0.e.y) }.reduce(0, +) / Double(max(turned.count, 1))
        print(String(format: "%@: %d frames  |dx| %.1f |dy| %.1f mm;  turned 5°+: %d frames |dx| %.1f |dy| %.1f mm", name, rows.count, mx, my, turned.count, tx, ty))
        if !CommandLine.arguments.contains("-v") { return }
        for (label, key) in [("yaw", { (r: (dyaw: Double, dpitch: Double, e: SIMD2<Double>)) in r.dyaw }), ("pitch", { $0.dpitch })] {
            for (lo, hi) in [(-40.0, -10.0), (-10, -5), (-5, -2), (-2, 2), (2, 5), (5, 10), (10, 40)] {
                let bin = rows.filter { (lo..<hi).contains(key($0)) }
                guard bin.count >= 5 else { continue }
                let mx = bin.map(\.e.x).reduce(0, +) / Double(bin.count), my = bin.map(\.e.y).reduce(0, +) / Double(bin.count)
                let ax = bin.map { abs($0.e.x) }.reduce(0, +) / Double(bin.count), ay = bin.map { abs($0.e.y) }.reduce(0, +) / Double(bin.count)
                print(String(format: "  %@ %+4.0f…%+4.0f°: %4d frames  mean dx %+6.1f dy %+6.1f   |dx| %5.1f |dy| %5.1f mm", label.padding(toLength: 5, withPad: " ", startingAt: 0), lo, hi, bin.count, mx, my, ax, ay))
            }
        }
    }
    table("head-motion targets, held out", leaveOneOut(mirrored, personalize: true, moving: true))
    table("  never trained on head motion", leaveOneOut(mirrored, personalize: true, moving: true, trainOnMoving: false, personalizeOnMoving: false))
    table("  one other head-motion target", leaveOneOut(mirrored, personalize: true, moving: true, movingKept: 1))
    table("  head motion in personalization only", leaveOneOut(mirrored, personalize: true, moving: true, trainOnMoving: false))
    table("  head motion in geometry fit only", leaveOneOut(mirrored, personalize: true, moving: true, personalizeOnMoving: false))
    table("  not personalized", leaveOneOut(mirrored, personalize: false, moving: true))
    table("still targets, held out", leaveOneOut(mirrored, personalize: true))
    exit(0)
}

/// `-quick`: only the leave-one-out score of the network as the app uses it (mirrored, personalized).
if CommandLine.arguments.contains("-quick") {
    printLOO("personalized+mirrored", leaveOneOut(rerun(mirrored: true), personalize: true))
    exit(0)
}

print("")
let looIris = leaveOneOut(estimates, personalize: false, source: .iris)
let looNetwork = leaveOneOut(estimates, personalize: false)
let looPersonal = leaveOneOut(estimates, personalize: true)
printLOO("iris", looIris)
printLOO("network", looNetwork)
printLOO("personalized", looPersonal)

let plainStart = Date()
_ = rerun()
let plainTime = Date().timeIntervalSince(plainStart)
let mirroredStart = Date()
let mirroredEstimates = rerun(mirrored: true)
print(String(format: "network per frame (incl. warp, head pose): plain %.1f ms, mirrored %.1f ms", plainTime * 1000 / Double(session.frames.count), Date().timeIntervalSince(mirroredStart) * 1000 / Double(session.frames.count)))
let looMirrored = leaveOneOut(mirroredEstimates, personalize: true)
printLOO("personalized+mirrored", looMirrored)

for (name, net) in [("personalized", looPersonal), ("pers+mirrored", looMirrored)] {
    print("\(name) blended with iris (rows: weight on network x, columns: y; error x/y mm):")
    let weights = [0.0, 0.25, 0.5, 0.75, 1.0]
    print("        " + weights.map { String(format: "  y %.2f   ", $0) }.joined())
    for wx in weights {
        let row = weights.map { wy -> String in let e = errors(blend(looIris, net, SIMD2(wx, wy))); return String(format: "%5.1f/%5.1f ", e.x, e.y) }
        print(String(format: "  x %.2f ", wx) + row.joined())
    }
}

// MARK: Head pose fit quality
do {
    let estimator = HeadPoseEstimator(face: face)
    var ratios: [Double] = []
    for frame in session.frames {
        let intrinsics = CameraIntrinsics(imageWidth: frame.imageSize.x, imageHeight: frame.imageSize.y, horizontalFOVDegrees: GazeModel.defaultFieldOfView)
        guard let pose = estimator.estimate(frame.landmarks, intrinsics: intrinsics, time: frame.timestamp),
              let a = frame.landmarks[0], let b = frame.landmarks[3] else { continue }
        ratios.append(pose.fitError / simd_length(b - a))
    }
    ratios.sort()
    print(String(format: "\nHead pose fit error / eye span: median %.4f, p90 %.4f, p99 %.4f; above 0.02: %d of %d",
                 ratios[ratios.count / 2], ratios[ratios.count * 9 / 10], ratios[ratios.count * 99 / 100], ratios.filter { $0 > 0.02 }.count, ratios.count))
}
