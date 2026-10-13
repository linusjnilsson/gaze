import Foundation
import GazeKit

/// Saves a calibration session's frames (face crops plus measurements and targets) so tracking
/// methods can be evaluated offline on real data, in `Recordings/<date>/` next to the profiles.
enum CalibrationRecorder {
    struct Session: Encodable {
        var createdAt: Date
        var displays: [DisplayInfo]
        var frames: [Frame]
    }

    struct Frame: Encodable {
        var file: String?
        /// The crop within the full frame, in pixels with a lower-left origin.
        var crop: CGRect?
        var timestamp: TimeInterval
        var targetIndex: Int
        /// Global AppKit coordinates.
        var target: CGPoint
        var displayIndex: Int
        var moveHead: Bool
        var imageSize: SIMD2<Double>
        /// Full-frame pixels, lower-left origin, in `FaceShape.landmarks` order.
        var landmarks: [SIMD2<Double>?]
        var irisImageLeft: SIMD2<Double>
        var irisImageRight: SIMD2<Double>
        var networkGaze: SIMD3<Double>?
    }

    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Gaze/Recordings", isDirectory: true)
    }

    static func newSessionURL() -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return directory?.appendingPathComponent(formatter.string(from: .now), isDirectory: true)
    }

    /// Fixed targets keep their order's index; stretches of the moving dot are numbered from
    /// `CalibrationController.pursuitTargetIndexBase`, each frame with where the dot was.
    static func write(_ targets: [(index: Int, entry: CalibrationController.Collected)], displays: [DisplayInfo], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var frames: [Frame] = []
            for (targetIndex, target) in targets {
                for (sample, point) in target.frames {
                    var file: String?
                    if let image = sample.image {
                        let name = String(format: "%05d.jpg", frames.count)
                        try image.jpeg.write(to: url.appendingPathComponent(name))
                        file = name
                    }
                    let m = sample.measurements
                    frames.append(Frame(
                        file: file,
                        crop: sample.image?.rect,
                        timestamp: sample.timestamp,
                        targetIndex: targetIndex,
                        target: point,
                        displayIndex: target.displayIndex,
                        moveHead: target.moveHead,
                        imageSize: m.imageSize,
                        landmarks: m.landmarks,
                        irisImageLeft: m.irisImageLeft,
                        irisImageRight: m.irisImageRight,
                        networkGaze: m.networkGaze
                    ))
                }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(Session(createdAt: .now, displays: displays, frames: frames))
                .write(to: url.appendingPathComponent("session.json"))
        } catch {
            NSLog("Gaze: could not save calibration recording: \(error)")
        }
    }
}
