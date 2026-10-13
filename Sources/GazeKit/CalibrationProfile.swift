import CoreGraphics
import Foundation

/// How far predictions landed from validation targets the model was not trained on.
public struct ValidationReport: Sendable, Codable, Equatable {
    public struct TargetError: Sendable, Codable, Equatable {
        public var target: CGPoint
        public var estimate: CGPoint
        public var millimetersPerPoint: Double
        /// Whether the user was asked to move their head while looking at this target.
        public var headMoving: Bool

        public init(target: CGPoint, estimate: CGPoint, millimetersPerPoint: Double, headMoving: Bool) {
            self.target = target
            self.estimate = estimate
            self.millimetersPerPoint = millimetersPerPoint
            self.headMoving = headMoving
        }

        public var points: Double { hypot(estimate.x - target.x, estimate.y - target.y) }
        public var millimeters: Double { points * millimetersPerPoint }
    }

    /// Degrees are reported for a typical laptop viewing distance; the true distance is not measured yet.
    public static let assumedViewingDistanceMM = 600.0

    public var targets: [TargetError]
    /// The gaze source that was validated. `nil` in older profiles, which only had the iris.
    public var source: GazeSource?
    /// The same targets with the sources that weren't chosen, for comparison.
    public var alternatives: [ValidationReport]?

    public init(targets: [TargetError], source: GazeSource = .iris) {
        self.targets = targets
        self.source = source
    }

    public var gazeSource: GazeSource { source ?? .iris }

    public var meanErrorPoints: Double { mean(targets.map(\.points)) }
    public var meanErrorMillimeters: Double { mean(targets.map(\.millimeters)) }
    public var meanErrorDegrees: Double { degrees(meanErrorMillimeters) }

    /// Error with the head held still, in millimeters.
    public var stillErrorMillimeters: Double { mean(targets.filter { !$0.headMoving }.map(\.millimeters)) }
    /// Error while the head was moving, in millimeters.
    public var movingErrorMillimeters: Double { mean(targets.filter(\.headMoving).map(\.millimeters)) }

    public func degrees(_ millimeters: Double) -> Double {
        atan(millimeters / Self.assumedViewingDistanceMM) * 180 / .pi
    }

    private func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }
}

/// A named setup: a calibration for one set of displays, plus everything learned since.
///
/// Several profiles can share the same displays, e.g. "Home" and "Café" for the laptop alone, where
/// seating, lighting and camera angle differ. When the displays change, the most recently used
/// matching profile is picked automatically.
public struct CalibrationProfile: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var signature: String
    public var displays: [DisplayInfo]
    /// The model in use: the explicit calibration, refined by learning from interactions.
    public var model: GazeModel
    /// The explicit calibration that learning is anchored to. `nil` in older profiles, where it equals `model`.
    public var calibratedModel: GazeModel?
    public var validation: ValidationReport?
    public var createdAt: Date
    /// When this profile was last active, to pick between profiles for the same displays.
    public var lastUsed: Date?
    /// Learning samples: the calibration frames plus what was learned from clicks and typing.
    public var interactions: [InteractionSample]?
    public var lastAdjusted: Date?
    /// Typical interaction error (mm) after the last adjustment, for detecting drift.
    public var learningBaseline: Double?

    public init(id: UUID = UUID(), name: String? = nil, signature: String, displays: [DisplayInfo], model: GazeModel, validation: ValidationReport?, createdAt: Date = .now) {
        self.id = id
        self.name = name ?? Self.defaultName(for: displays)
        self.signature = signature
        self.displays = displays
        self.model = model
        calibratedModel = model
        self.validation = validation
        self.createdAt = createdAt
        lastUsed = createdAt
    }

    /// Replaces the calibration, keeping the profile's identity and name. What was learned with the
    /// old calibration is dropped: it was measured against that calibration's geometry.
    public mutating func recalibrate(model: GazeModel, validation: ValidationReport?, samples: [InteractionSample], displays: [DisplayInfo], signature: String) {
        self.model = model
        calibratedModel = model
        self.validation = validation
        self.displays = displays
        self.signature = signature
        createdAt = .now
        lastUsed = .now
        interactions = samples
        lastAdjusted = nil
        learningBaseline = nil
    }

    /// "Built-in Display", or e.g. "Built-in Display + DELL U2720Q".
    public static func defaultName(for displays: [DisplayInfo]) -> String {
        let names = displays.sorted { $0.isBuiltin && !$1.isBuiltin }.map(\.name)
        return names.isEmpty ? "Profile" : names.joined(separator: " + ")
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, signature, displays, model, calibratedModel, validation, createdAt, lastUsed, interactions, lastAdjusted, learningBaseline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        signature = try c.decode(String.self, forKey: .signature)
        displays = try c.decode([DisplayInfo].self, forKey: .displays)
        model = try c.decode(GazeModel.self, forKey: .model)
        calibratedModel = try c.decodeIfPresent(GazeModel.self, forKey: .calibratedModel)
        validation = try c.decodeIfPresent(ValidationReport.self, forKey: .validation)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        interactions = try c.decodeIfPresent([InteractionSample].self, forKey: .interactions)
        lastAdjusted = try c.decodeIfPresent(Date.self, forKey: .lastAdjusted)
        learningBaseline = try c.decodeIfPresent(Double.self, forKey: .learningBaseline)
        // Profiles from before named profiles were stored one per display setup, without these.
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.defaultName(for: displays)
    }
}

/// Stores profiles as one file each in Application Support.
public enum CalibrationStore {
    public static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Gaze/Profiles", directoryHint: .isDirectory)
    }

    /// Every saved profile. Files from before named profiles (named by display signature) are moved
    /// to their new name on the way.
    public static func loadAll() -> [CalibrationProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let profile = try? JSONDecoder().decode(CalibrationProfile.self, from: data)
            else { return nil }
            if url.deletingPathExtension().lastPathComponent != profile.id.uuidString,
               (try? save(profile)) != nil {
                try? FileManager.default.removeItem(at: url)
            }
            return profile
        }
    }

    public static func save(_ profile: CalibrationProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(profile).write(to: url(for: profile.id), options: .atomic)
    }

    public static func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }

    private static func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}
