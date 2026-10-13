import AppKit
import Foundation
import Observation
import simd

/// Keeps the calibration accurate by learning from everyday clicks and typing.
///
/// **When it learns.** An interaction is used only if it's a moment you were almost certainly
/// looking at the target: a deliberate click (the cursor traveled to it; not a double or repeated
/// click) or the start of a typing burst; the face and both irises were tracked reliably; and your
/// gaze had settled on one spot just before. Every skip is counted by reason, see `skipped`.
///
/// **How it learns.** Every frame of the settled gaze is kept, grouped into one event. Every
/// `refitInterval` new events (sooner when accuracy drops) the model is refit in the background
/// from the calibration frames plus everyday events, weighted by trust, recency and screen
/// coverage, and adopted only if it beats the current model on recent events it didn't see.
@MainActor
@Observable
public final class InteractionLearner {
    public enum Status: Equatable, Sendable {
        case notCalibrated
        /// Gathering the first everyday interactions.
        case collecting
        case learning
        /// Recent accuracy is clearly worse than before: conditions changed (lighting, glasses, …).
        case drifting
    }

    /// Why an interaction wasn't learned from.
    public enum SkipReason: String, CaseIterable, Sendable {
        case cursorDidNotTravel = "Cursor hadn't moved to the click"
        case repeatedClick = "Double or repeated click"
        case trackingUnreliable = "Face or eyes not tracked well"
        case eyesMoving = "Eyes hadn't settled"
        case notLooking = "Probably not looking at the target"
        case offScreen = "Target outside known displays"
    }

    /// The outcome of a refit that was adopted, measured on held-out recent interactions.
    public struct Improvement: Equatable, Sendable {
        /// Typical error in millimeters before and after.
        public var before: Double
        public var after: Double
        public var date: Date
        /// The network's personalization was relearned from everyday interactions.
        public var personalized = false
    }

    public var isEnabled = true
    /// Calibration frames plus learned everyday frames.
    public private(set) var samples: [InteractionSample] = []
    public private(set) var lastImprovement: Improvement?
    public private(set) var lastAdjusted: Date?
    /// Prediction errors (mm) at recent qualifying interactions, whether or not they were learned from.
    public private(set) var recentErrors: [Double] = []
    /// The typical error after the last adjustment; drift is measured against it.
    public private(set) var baselineError: Double?
    public private(set) var isDrifting = false
    /// Interactions learned from since launch.
    public private(set) var acceptedThisSession = 0
    /// Interactions skipped since launch, by reason.
    public private(set) var skipped: [SkipReason: Int] = [:]

    /// Typical error over recent interactions: a live accuracy measure.
    public var liveErrorMillimeters: Double? {
        recentErrors.count >= 5 ? median(recentErrors) : nil
    }

    public var everydayEventCount: Int {
        Set(samples.lazy.filter { $0.source != .calibration }.map(\.event)).count
    }

    public var status: Status {
        if base == nil { return .notCalibrated }
        if isDrifting { return .drifting }
        return everydayEventCount < LearningFit.holdOutMinimumEvents ? .collecting : .learning
    }

    /// Called after a refit is adopted, with the new model and everything learned so far.
    @ObservationIgnored public var onAdapt: ((GazeModel, [InteractionSample], Improvement) -> Void)?
    /// Called after an interaction is learned from, with everything learned so far.
    @ObservationIgnored public var onRecord: (([InteractionSample]) -> Void)?

    @ObservationIgnored private let engine: GazeEngine
    @ObservationIgnored private var base: GazeModel?
    @ObservationIgnored private var newEvents = 0
    @ObservationIgnored private var fitTask: Task<Void, Never>?
    @ObservationIgnored private var cursorTrail: [(time: TimeInterval, point: CGPoint)] = []
    @ObservationIgnored private var lastClick: (time: TimeInterval, point: CGPoint)?

    static let everydayCapacity = 2500
    static let refitInterval = 12
    static let driftRefitInterval = 6
    static let errorWindow = 50
    /// Points the cursor must have moved in the moment before a click for it to count as aimed.
    static let minimumCursorTravel = 40.0
    /// Millimeters the gaze may wander in the moment before an interaction and still count as settled.
    static let maximumGazeDispersion = 45.0

    public init(engine: GazeEngine) {
        self.engine = engine
        _ = engine.addSampleObserver { [weak self] _ in
            self?.trackCursor()
        }
    }

    /// Starts over from an explicit calibration and its learning samples, or restores saved state.
    public func reset(base: GazeModel?, samples: [InteractionSample] = [], lastAdjusted: Date? = nil, baselineError: Double? = nil) {
        fitTask?.cancel()
        fitTask = nil
        self.base = base
        self.samples = samples
        self.lastAdjusted = lastAdjusted
        self.baselineError = baselineError
        lastImprovement = nil
        newEvents = 0
        recentErrors = []
        isDrifting = false
    }

    /// Records an interaction at `target` (global screen coordinates) that happened at `uptime`
    /// (system uptime, as in `NSEvent.timestamp`).
    public func record(_ source: InteractionSample.Source, at target: CGPoint, uptime: TimeInterval) {
        guard let model = engine.model, base != nil else { return }

        if source == .click {
            let previous = lastClick
            lastClick = (uptime, target)
            if let previous, uptime - previous.time < 0.7, hypot(target.x - previous.point.x, target.y - previous.point.y) < 30 {
                return skip(.repeatedClick)
            }
            // People often click without looking when the cursor is already in place (pressing a
            // button repeatedly while reading elsewhere). Aimed clicks are the ones to trust.
            guard cursorTravel(before: uptime, to: target) >= Self.minimumCursorTravel else {
                return skip(.cursorDidNotTravel)
            }
        }

        guard let plane = model.planes.first(where: { $0.frame.contains(target) }) else { return skip(.offScreen) }

        let window = source.gazeWindow
        let frames = engine.frames(from: uptime - window.start, to: uptime - window.end).filter(\.isReliable)
        let hits = frames.compactMap { frame in model.hit(on: plane, for: frame.observation).map { (frame, $0) } }
        guard hits.count >= 4 else { return skip(.trackingUnreliable) }

        // Settled gaze: the predicted point stays put. (Not the eye angles: they change when the
        // head moves while looking at one spot.)
        let center = SIMD2(median(hits.map(\.1.x)), median(hits.map(\.1.y)))
        guard hits.allSatisfy({ simd_length($0.1 - center) < Self.maximumGazeDispersion }) else {
            return skip(.eyesMoving)
        }

        let error = simd_length(center - plane.local(from: target))
        recordError(error)
        guard error < acceptanceRadius(for: source) else { return skip(.notLooking) }
        guard isEnabled else { return }

        samples += InteractionSample.event(
            hits.map { frame, _ in (frame.observation, frame.measurements.networkReading) },
            target: target,
            displayID: plane.displayID,
            source: source,
            date: .now
        )
        trimToCapacity()
        acceptedThisSession += 1
        onRecord?(samples)
        newEvents += 1
        if newEvents >= (isDrifting ? Self.driftRefitInterval : Self.refitInterval) {
            refit()
        }
    }

    /// How far off (mm) an interaction may be predicted and still be assumed looked at. It scales
    /// with recent accuracy, so if tracking drifts the learner keeps accepting the samples it needs
    /// to recover instead of locking itself out.
    func acceptanceRadius(for source: InteractionSample.Source) -> Double {
        let live = liveErrorMillimeters ?? 50
        switch source {
        case .calibration: return .infinity
        case .click: return min(180, max(60, 3 * live))
        case .typing: return min(120, max(50, 2 * live))
        }
    }

    private func skip(_ reason: SkipReason) {
        skipped[reason, default: 0] += 1
    }

    private func recordError(_ error: Double) {
        recentErrors.append(error)
        if recentErrors.count > Self.errorWindow {
            recentErrors.removeFirst(recentErrors.count - Self.errorWindow)
        }
        if baselineError == nil, recentErrors.count >= 20 {
            baselineError = median(recentErrors)
        }
        if let baselineError, recentErrors.count >= 15 {
            let recent = median(Array(recentErrors.suffix(15)))
            isDrifting = recent > max(baselineError * 1.6, baselineError + 12)
        }
    }

    private func trackCursor() {
        let now = ProcessInfo.processInfo.systemUptime
        cursorTrail.append((now, NSEvent.mouseLocation))
        cursorTrail.removeAll { $0.time < now - 2 }
    }

    /// Path length (points) the cursor traveled in the 1.2 s before `uptime`, ending at `target`.
    private func cursorTravel(before uptime: TimeInterval, to target: CGPoint) -> Double {
        let path = cursorTrail.filter { $0.time >= uptime - 1.2 && $0.time <= uptime }.map(\.point) + [target]
        return zip(path, path.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Drops the oldest everyday frames beyond capacity. Calibration frames are always kept.
    private func trimToCapacity() {
        let everyday = samples.count { $0.source != .calibration }
        guard everyday > Self.everydayCapacity else { return }
        var excess = everyday - Self.everydayCapacity
        samples.removeAll { sample in
            guard excess > 0, sample.source != .calibration else { return false }
            excess -= 1
            return true
        }
    }

    private func refit() {
        guard fitTask == nil, let base, let current = engine.model else { return }
        newEvents = 0
        let snapshot = samples
        let now = Date.now
        // After conditions change, lean on recent data.
        let halfLife: TimeInterval = isDrifting ? 86400 : 7 * 86400
        fitTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                LearningFit.refit(base: base, current: current, samples: snapshot, now: now, recencyHalfLife: halfLife)
            }.value
            guard let self, !Task.isCancelled else { return }
            fitTask = nil
            guard let outcome else { return }

            engine.model = outcome.model
            let improvement = Improvement(before: outcome.before, after: outcome.after, date: now, personalized: outcome.personalized)
            lastImprovement = improvement
            lastAdjusted = now
            baselineError = outcome.after
            // Errors measured with the old model no longer describe the new one.
            recentErrors = []
            isDrifting = false
            onAdapt?(outcome.model, samples, improvement)
        }
    }
}

/// Refits and decides whether the result is an improvement, judged on interactions it never saw.
enum LearningFit {
    struct Outcome: Sendable {
        var model: GazeModel
        /// Typical error (mm) on held-out recent interactions with the current and the new model.
        var before: Double
        var after: Double
        /// Whether the network's personalization was relearned from everyday interactions.
        var personalized = false
    }

    /// Everyday events needed before some can be held out to judge a refit.
    static let holdOutMinimumEvents = 25

    static func refit(base: GazeModel, current: GazeModel, samples: [InteractionSample], now: Date, recencyHalfLife: TimeInterval) -> Outcome? {
        let everyday = samples.filter { $0.source != .calibration }
        let events = orderedEvents(everyday)
        guard events.count >= 8 else { return nil }

        func adapt(_ data: [InteractionSample], personalize: Bool = false) -> GazeModel? {
            GazeModel.adapt(base, to: data, now: now, recencyHalfLife: recencyHalfLife, personalize: personalize)
        }

        guard events.count >= holdOutMinimumEvents else {
            // Too few to hold any back. The geometric fit has few parameters (no correction layer
            // this early), so judging it on its own data is still meaningful.
            guard let candidate = adapt(samples) else { return nil }
            let before = typicalError(current, everyday), after = typicalError(candidate, everyday)
            return after < before ? Outcome(model: candidate, before: before, after: after) : nil
        }

        let heldOut = Set(events.suffix(max(5, events.count / 5)))
        let train = samples.filter { !heldOut.contains($0.event) }
        let test = samples.filter { heldOut.contains($0.event) }
        let before = typicalError(current, test)
        // With enough clicks carrying the network's features, also try relearning its
        // personalization, and keep whichever does better on the held-out clicks.
        let personalizable = base.gazeSource == .network
            && Set(train.filter { $0.source != .calibration && $0.features != nil }.map(\.event)).count >= GazeModel.personalizationMinimumEvents
        let candidates = (personalizable ? [false, true] : [false]).compactMap { personalize in
            adapt(train, personalize: personalize).map { (personalize, typicalError($0, test)) }
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 }), best.1 < before * 0.99 else { return nil }
        // Confirmed on unseen data; now use everything, including the held-out events.
        guard let final = adapt(samples, personalize: best.0) else { return nil }
        return Outcome(model: final, before: before, after: best.1, personalized: best.0)
    }

    /// Median over events of each event's median frame error, in millimeters, with frames
    /// observed through `model`'s own network personalization.
    static func typicalError(_ model: GazeModel, _ samples: [InteractionSample]) -> Double {
        let samples = model.gazeSource == .network ? samples.rebased(to: model.featureCorrection) : samples
        let errors = Dictionary(grouping: samples, by: \.event).values.compactMap { frames -> Double? in
            let e = frames.compactMap(model.error(for:))
            return e.isEmpty ? nil : median(e)
        }
        return errors.isEmpty ? .infinity : median(errors)
    }

    /// Event IDs, oldest first.
    static func orderedEvents(_ samples: [InteractionSample]) -> [UUID] {
        var first: [UUID: Date] = [:]
        for s in samples {
            first[s.event] = min(first[s.event] ?? s.date, s.date)
        }
        return first.sorted { $0.value < $1.value }.map(\.key)
    }
}
