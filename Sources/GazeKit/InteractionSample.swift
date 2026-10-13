import CoreGraphics
import Foundation

/// One camera frame from a moment where we know (approximately) where the user was looking.
public struct InteractionSample: Sendable, Equatable {
    public enum Source: String, Sendable, Codable {
        /// Looking at a calibration dot. The most precise label we get.
        case calibration
        /// The cursor position at a deliberate mouse click. People look at what they click.
        case click
        /// The text cursor when starting to type. Weaker: people also glance at the keyboard.
        case typing

        /// How much one event of this kind is trusted, relative to a click.
        public var weight: Double {
            switch self {
            case .calibration: 2
            case .click: 1
            case .typing: 0.5
            }
        }

        /// The stretch before the event, in seconds, when the eyes are on the target.
        var gazeWindow: (start: Double, end: Double) {
            switch self {
            case .calibration, .click: (0.45, 0.05)
            case .typing: (0.35, 0)
            }
        }

        /// Calibration data ages more slowly than everyday interactions.
        var halfLifeMultiplier: Double {
            self == .calibration ? 4 : 1
        }
    }

    public var observation: GazeObservation
    /// Global AppKit screen coordinates.
    public var target: CGPoint
    public var displayID: UInt32
    public var source: Source
    public var date: Date
    /// Frames from the same interaction share an event, and together carry one event's weight.
    public var event: UUID
    /// The gaze network's own estimate on this frame, before personalization, so the frame can be
    /// redone with a newly learned personalization.
    public var network: NetworkFrame?
    /// The network's features averaged over the event, for learning the personalization. Only on
    /// the event's last frame (trimming drops the oldest frames first), to keep profiles small.
    public var features: [Float]?

    public init(observation: GazeObservation, target: CGPoint, displayID: UInt32, source: Source, date: Date, event: UUID = UUID(), network: NetworkFrame? = nil, features: [Float]? = nil) {
        self.observation = observation
        self.target = target
        self.displayID = displayID
        self.source = source
        self.date = date
        self.event = event
        self.network = network
        self.features = features
    }

    /// Samples for one interaction's frames, carrying what the network saw for learning its
    /// personalization later.
    public static func event(
        _ frames: [(observation: GazeObservation, reading: NetworkReading?)],
        target: CGPoint,
        displayID: UInt32,
        source: Source,
        date: Date
    ) -> [InteractionSample] {
        event(frames.map { ($0.observation, $0.reading, target) }, displayID: displayID, source: source, date: date)
    }

    /// Samples for one event whose frames each have their own target, like a stretch of following
    /// a moving dot.
    public static func event(
        _ frames: [(observation: GazeObservation, reading: NetworkReading?, target: CGPoint)],
        displayID: UInt32,
        source: Source,
        date: Date
    ) -> [InteractionSample] {
        let event = UUID()
        let readings = frames.compactMap(\.reading)
        var samples = frames.map { frame in
            InteractionSample(
                observation: frame.observation,
                target: frame.target,
                displayID: displayID,
                source: source,
                date: date,
                event: event,
                network: frame.reading.map { NetworkFrame(angles: $0.angles, normalization: $0.normalization) }
            )
        }
        if let dimension = readings.first?.features.count, !samples.isEmpty {
            var mean = [Float](repeating: 0, count: dimension)
            for reading in readings where reading.features.count == dimension {
                for i in 0..<dimension { mean[i] += reading.features[i] }
            }
            samples[samples.count - 1].features = mean.map { $0 / Float(readings.count) }
        }
        return samples
    }
}

/// The network's uncorrected (pitch, yaw) and the normalized camera they're in.
public struct NetworkFrame: Sendable, Equatable, Codable {
    public var angles: SIMD2<Double>
    public var normalization: FaceNormalization

    public init(angles: SIMD2<Double>, normalization: FaceNormalization) {
        self.angles = angles
        self.normalization = normalization
    }

    /// The direction with `correction` applied for an event's `features`.
    func direction(correction: FeatureCorrection?, features: [Float]?) -> Vec3 {
        let corrected = angles + (features.flatMap { correction?.correction(for: $0) } ?? .zero)
        return normalization.gazeDirection(pitch: corrected.x, yaw: corrected.y)
    }
}

extension [InteractionSample] {
    /// Each event's features, from whichever of its frames carries them.
    var featuresByEvent: [UUID: [Float]] {
        var result: [UUID: [Float]] = [:]
        for sample in self {
            if let features = sample.features { result[sample.event] = features }
        }
        return result
    }

    /// The samples as they'd have been observed with `correction` personalizing the network.
    /// Frames without network data (iris tracking, older samples) stay as they are.
    func rebased(to correction: FeatureCorrection?) -> [InteractionSample] {
        let features = featuresByEvent
        return map { sample in
            guard let network = sample.network, let eventFeatures = features[sample.event] else { return sample }
            var rebased = sample
            rebased.observation = sample.observation.withGaze(network.direction(correction: correction, features: eventFeatures))
            return rebased
        }
    }
}

extension InteractionSample: Codable {
    private enum CodingKeys: String, CodingKey {
        case observation, target, displayID, source, date, event, network, features
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            observation: try c.decode(GazeObservation.self, forKey: .observation),
            target: try c.decode(CGPoint.self, forKey: .target),
            displayID: try c.decode(UInt32.self, forKey: .displayID),
            source: try c.decode(Source.self, forKey: .source),
            date: try c.decode(Date.self, forKey: .date),
            // Samples saved before events existed were one frame per interaction.
            event: try c.decodeIfPresent(UUID.self, forKey: .event) ?? UUID(),
            network: try c.decodeIfPresent(NetworkFrame.self, forKey: .network),
            features: try c.decodeIfPresent(Data.self, forKey: .features).map(Self.floats)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observation, forKey: .observation)
        try c.encode(target, forKey: .target)
        try c.encode(displayID, forKey: .displayID)
        try c.encode(source, forKey: .source)
        try c.encode(date, forKey: .date)
        try c.encode(event, forKey: .event)
        try c.encodeIfPresent(network, forKey: .network)
        // Raw bytes (base64 in JSON): a third the size of 512 numbers written out.
        try c.encodeIfPresent(features.map { $0.withUnsafeBufferPointer { Data(buffer: $0) } }, forKey: .features)
    }

    private static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
