import AppKit
import GazeKit
import Observation
import SwiftUI

enum CalibrationError: LocalizedError {
    case notEnoughData

    var errorDescription: String? {
        switch self {
        case .notEnoughData: "Not enough usable frames. Make sure your face is well lit and visible to the camera."
        }
    }
}

/// Runs the calibrate → fit → validate sequence on full-screen overlays across all displays.
@MainActor
@Observable
final class CalibrationController {
    enum Phase: Equatable {
        case idle
        case intro
        case calibrating
        case fitting
        case validating
        case finished(ValidationReport)
        case failed(String)
    }

    /// The parts of a calibration, each introduced by a card that says what to do.
    enum Stage: Int, CaseIterable {
        case dots, follow, followAgain, turnHead, check

        var title: String {
            switch self {
            case .dots: "Look at each dot"
            case .follow: "Follow the moving dot"
            case .followAgain: "Change posture, follow again"
            case .turnHead: "Turn your head"
            case .check: "Check accuracy"
            }
        }

        var shortTitle: String {
            switch self {
            case .dots: "Dots"
            case .follow: "Follow"
            case .followAgain: "Follow again"
            case .turnHead: "Turn head"
            case .check: "Check"
            }
        }

        var instruction: String {
            switch self {
            case .dots: "Keep your eyes on each dot until the next appears. When an arrow circles a dot, keep looking at the dot and move your head in a slow circle along with the arrow."
            case .follow: "A dot glides across the screen. Follow it with your eyes and keep your head still."
            case .followAgain: "Lean back a little or shift to one side, the way you also sit at times. Then follow the dot again."
            case .turnHead: "Keep your eyes on the dot while you move your head in a slow circle along with the arrow. Make the circle wide, as far as the screen stays comfortable to look at."
            case .check: "A few last dots, to measure how accurate the calibration is. Sit as you did at the start."
            }
        }

        var symbol: String {
            switch self {
            case .dots: "circle.grid.3x3"
            case .follow: "point.topleft.down.to.point.bottomright.curvepath"
            case .followAgain: "figure.seated.side.left"
            case .turnHead: "arrow.triangle.2.circlepath"
            case .check: "checkmark.seal"
            }
        }
    }

    /// A dot to look at, and whether to move the head while looking at it.
    struct Target {
        var point: CGPoint
        var displayIndex: Int
        var moveHead: Bool
    }

    /// A dot gliding across a display for the eyes to follow, which labels hundreds of frames all
    /// over the screen where the fixed dots label a dozen spots.
    struct Pursuit {
        var kind: PursuitPath.Kind
        var display: CGRect
        var displayIndex: Int
        /// `CACurrentMediaTime()` when the dot starts moving; camera frames carry the same clock.
        var start: TimeInterval

        /// Before this, the eyes are still catching up with the dot.
        static let settle: TimeInterval = 1
        /// The eyes, and the screen showing the dot, trail where it's computed to be.
        static let lag: TimeInterval = 0.05
        /// Frames are grouped into stretches this long, each standing in for one target.
        static let segment: TimeInterval = 0.5

        var duration: TimeInterval { PursuitPath.duration(kind) }

        func point(at time: TimeInterval) -> CGPoint {
            PursuitPath.point(kind, in: display, at: time - start)
        }
    }

    /// Frames collected for one target, or one stretch of a pursuit, each with where the user looked.
    struct Collected {
        var displayIndex: Int
        var moveHead: Bool
        var frames: [(sample: FaceSample, target: CGPoint)]
    }

    /// Pursuit stretches are numbered from here, apart from the fixed targets: the sweep from the
    /// first, the loops (in a second posture) from the second.
    static let pursuitTargetIndexBase = 10_000
    static let secondPostureTargetIndexBase = 20_000
    /// Stretches of holding a dot while turning the head are numbered from here.
    static let headMotionTargetIndexBase = 30_000

    /// Where the dot rests while the head turns, as (x, y) shares from the top-left, and how long.
    static let headMotionSpots: [(Double, Double)] = [(0.5, 0.5), (0.15, 0.2), (0.85, 0.2), (0.85, 0.8), (0.15, 0.8)]
    static let headMotionDuration: TimeInterval = 3.5

    private(set) var phase: Phase = .idle
    private(set) var target: Target?
    private(set) var pursuit: Pursuit?
    private(set) var stage: Stage?
    /// When the current stage's card appeared (`CACurrentMediaTime()`), while it's shown.
    private(set) var announcedAt: TimeInterval?
    private(set) var isCollecting = false
    private(set) var stageStep = 0
    private(set) var stageStepCount = 0
    /// When the arrow around a head-motion dot started circling.
    private(set) var headTurnStart: TimeInterval?

    /// How long each stage's card shows before its first dot.
    static let announceDuration: TimeInterval = 4.5
    /// One circle of the head-motion arrow.
    static let headCirclePeriod: TimeInterval = 3

    var isActive: Bool { phase != .idle }

    /// Whether the camera has seen a usable face in the last moment.
    var seesFace: Bool { CACurrentMediaTime() - lastSampleTime < 0.6 }

    @ObservationIgnored private var windows: [OverlayWindow] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var buffer: [FaceSample] = []
    /// When each buffered frame reached the app, by `CACurrentMediaTime()`.
    @ObservationIgnored private var arrivals: [TimeInterval] = []
    @ObservationIgnored private var onClose: (() -> Void)?
    @ObservationIgnored private var lastSampleTime: TimeInterval = -.infinity
    @ObservationIgnored private var startRequested = false

    /// With `recordTo`, every frame is also saved there (face crops and measurements) for offline evaluation.
    func start(
        engine: GazeEngine,
        displays: [DisplayInfo],
        recordTo recording: URL? = nil,
        onComplete: @escaping (GazeModel, ValidationReport, [InteractionSample]) -> Void,
        onClose: @escaping () -> Void
    ) {
        guard !isActive, !displays.isEmpty else { return }
        self.onClose = onClose
        phase = .intro
        showWindows(displays: displays)

        let observer = engine.addSampleObserver { [weak self] sample in
            guard let self else { return }
            lastSampleTime = CACurrentMediaTime()
            guard isCollecting else { return }
            buffer.append(sample)
            arrivals.append(CACurrentMediaTime())
        }
        engine.capturesFaceImages = recording != nil
        engine.isCalibrating = true
        task = Task { [weak self] in
            defer {
                engine.removeSampleObserver(observer)
                engine.capturesFaceImages = false
                engine.isCalibrating = false
            }
            guard let self else { return }
            do {
                let (model, report, samples) = try await run(engine: engine, displays: displays, recordTo: recording)
                onComplete(model, report, samples)
            } catch is CancellationError {
                // Closed by the user.
            } catch {
                target = nil
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func close() {
        task?.cancel()
        task = nil
        windows.forEach { $0.close() }
        windows = []
        NSCursor.unhide()
        phase = .idle
        target = nil
        pursuit = nil
        stage = nil
        announcedAt = nil
        headTurnStart = nil
        startRequested = false
        isCollecting = false
        onClose?()
        onClose = nil
    }

    private func run(engine: GazeEngine, displays: [DisplayInfo], recordTo recording: URL?) async throws -> (GazeModel, ValidationReport, [InteractionSample]) {
        let calibrationTargets = displays.indices.flatMap { Self.calibrationTargets(on: displays[$0].frame, displayIndex: $0) }
        let validationTargets = displays.indices.flatMap { Self.validationTargets(on: displays[$0].frame, displayIndex: $0) }
        startRequested = false
        while !startRequested { try await Task.sleep(for: .milliseconds(100)) }

        phase = .calibrating
        try await announce(.dots, steps: calibrationTargets.count)
        var samples: [CalibrationSample] = []
        var collected: [(index: Int, entry: Collected)] = []
        for (index, target) in calibrationTargets.enumerated() {
            let frames = try await collect(target)
            collected.append((index, Collected(displayIndex: target.displayIndex, moveHead: target.moveHead, frames: frames.map { ($0, target.point) })))
            samples += frames.map {
                CalibrationSample(measurements: $0.measurements, target: target.point, targetIndex: index, displayIndex: target.displayIndex)
            }
        }
        // The moving dot twice: a sweep through the whole screen as you sit, then loops along the
        // edges and into the corners after changing posture, so the fit also sees the head
        // somewhere else, as it will be at other times of the day.
        let passes: [(kind: PursuitPath.Kind, base: Int, stage: Stage)] = [
            (.sweep, Self.pursuitTargetIndexBase, .follow),
            (.loops, Self.secondPostureTargetIndexBase, .followAgain),
        ]
        for pass in passes {
            try await announce(pass.stage, steps: displays.count)
            var nextIndex = pass.base
            for (displayIndex, display) in displays.enumerated() {
                for segment in try await follow(pass.kind, on: display.frame, displayIndex: displayIndex) {
                    collected.append((nextIndex, segment))
                    samples += segment.frames.map {
                        CalibrationSample(measurements: $0.sample.measurements, target: $0.target, targetIndex: nextIndex, displayIndex: displayIndex)
                    }
                    nextIndex += 1
                }
            }
        }
        // Holding a dot while turning the head, at several spots: the estimate drifts as the head
        // turns away from how it was during the rest, and replaying recordings showed error with a
        // turned head still falling steeply with each head-motion target added.
        try await announce(.turnHead, steps: Self.headMotionSpots.count * displays.count)
        var nextIndex = Self.headMotionTargetIndexBase
        for (displayIndex, display) in displays.enumerated() {
            for relative in Self.headMotionSpots {
                let target = Target(point: Self.point(in: display.frame, relative), displayIndex: displayIndex, moveHead: true)
                for segment in try await turnHead(at: target) {
                    collected.append((nextIndex, segment))
                    samples += segment.frames.map {
                        CalibrationSample(measurements: $0.sample.measurements, target: $0.target, targetIndex: nextIndex, displayIndex: displayIndex)
                    }
                    nextIndex += 1
                }
            }
        }

        phase = .fitting
        target = nil
        let calibrationSamples = samples
        // Fit every source this session has data for; validation decides which to use.
        let fieldOfView = engine.calibrationFieldOfView
        let sources = GazeSource.allCases.filter { source in
            source == .iris || calibrationSamples.filter { $0.measurements.networkGaze != nil }.count * 10 >= calibrationSamples.count * 8
        }
        let models = await Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: GazeModel?.self) { group in
                for source in sources {
                    group.addTask { GazeModel.fit(calibrationSamples, displays: displays, source: source, fieldOfView: fieldOfView) }
                }
                return await group.reduce(into: [GazeModel]()) { if let model = $1 { $0.append(model) } }
            }
        }.value
        try Task.checkCancellation()
        guard !models.isEmpty else { throw CalibrationError.notEnoughData }

        phase = .validating
        try await announce(.check, steps: validationTargets.count)
        var errors: [GazeSource: [ValidationReport.TargetError]] = [:]
        var validationSamples: [CalibrationSample] = []
        for (offset, target) in validationTargets.enumerated() {
            let frames = try await collect(target)
            let index = calibrationTargets.count + offset
            collected.append((index, Collected(displayIndex: target.displayIndex, moveHead: target.moveHead, frames: frames.map { ($0, target.point) })))
            validationSamples += frames.map {
                CalibrationSample(measurements: $0.measurements, target: target.point, targetIndex: index, displayIndex: target.displayIndex)
            }
            for model in models {
                // Redo the 3D estimate with the face shape calibration just learned.
                let estimator = HeadPoseEstimator()
                let predictions = frames.compactMap { frame in
                    frame.measurements.observe(for: model, using: estimator).flatMap { model.predict($0.observation) }
                }
                guard !predictions.isEmpty else { continue }
                errors[model.gazeSource, default: []].append(.init(
                    target: target.point,
                    estimate: median(predictions),
                    millimetersPerPoint: displays[target.displayIndex].millimetersPerPoint,
                    headMoving: target.moveHead
                ))
            }
        }
        // The last dot is done: the refit below takes a moment, shown as such rather than as a
        // dot still waiting to be looked at.
        phase = .fitting
        target = nil
        if let recording {
            let frames = collected
            Task.detached(priority: .utility) {
                CalibrationRecorder.write(frames, displays: displays, to: recording)
            }
        }

        // Only sources validated on every target compete, so a source can't win by skipping hard ones.
        let reports = models.compactMap { model in
            errors[model.gazeSource].flatMap { $0.count == validationTargets.count ? (model, ValidationReport(targets: $0, source: model.gazeSource)) : nil }
        }
        // A handful of validation targets can't separate close results, and replaying recordings
        // (all targets, each left out in turn) shows the network well ahead of the iris. So it's
        // preferred unless it's clearly worse here.
        let iris = reports.first { $0.1.gazeSource == .iris }
        let network = reports.first { $0.1.gazeSource == .network }
        let best = network.flatMap { network in
            iris.map { network.1.meanErrorMillimeters <= 1.25 * $0.1.meanErrorMillimeters } ?? true ? network : nil
        } ?? iris
        guard let (fitted, chosen) = best else { throw CalibrationError.notEnoughData }
        var report = chosen
        report.alternatives = reports.map(\.1).filter { $0.source != chosen.source }

        // The validation targets are good data too: refit the chosen source on every target.
        let allSamples = calibrationSamples + validationSamples
        let source = fitted.gazeSource
        let refitted = await Task.detached(priority: .userInitiated) {
            GazeModel.fit(allSamples, displays: displays, source: source, fieldOfView: fieldOfView)
        }.value
        try Task.checkCancellation()
        let model = refitted ?? fitted

        target = nil
        phase = .finished(report)
        return (model, report, Self.learningSamples(collected, model: model, displays: displays))
    }

    /// Every calibration and validation frame, as precisely labeled data for continuous learning.
    private static func learningSamples(
        _ collected: [(index: Int, entry: Collected)],
        model: GazeModel,
        displays: [DisplayInfo]
    ) -> [InteractionSample] {
        let estimator = HeadPoseEstimator()
        let now = Date.now
        return collected.flatMap { _, entry in
            InteractionSample.event(
                entry.frames.compactMap { frame in
                    frame.sample.measurements.observe(for: model, using: estimator).map { ($0.observation, frame.sample.measurements.networkReading, frame.target) }
                },
                displayID: displays[entry.displayIndex].displayID,
                source: .calibration,
                date: now
            )
        }
    }

    /// Starts the calibration from the intro card.
    func begin() {
        if phase == .intro { startRequested = true }
    }

    /// Shows the card for `stage`, which says what to do, before its first dot.
    private func announce(_ next: Stage, steps: Int) async throws {
        isCollecting = false
        target = nil
        pursuit = nil
        headTurnStart = nil
        stage = next
        stageStep = 0
        stageStepCount = steps
        announcedAt = CACurrentMediaTime()
        try await Task.sleep(for: .seconds(Self.announceDuration))
        announcedAt = nil
    }

    /// Shows the dot, lets the eyes settle on it, then records frames.
    private func collect(_ next: Target) async throws -> [FaceSample] {
        isCollecting = false
        target = next
        headTurnStart = next.moveHead ? CACurrentMediaTime() : nil
        stageStep += 1
        try await Task.sleep(for: .milliseconds(next.moveHead ? 1100 : 850))
        buffer = []
        arrivals = []
        isCollecting = true
        try await Task.sleep(for: .milliseconds(next.moveHead ? 2200 : 900))
        isCollecting = false
        // Eye angles legitimately vary while the head moves, so only filter still targets.
        return next.moveHead ? buffer : buffer.rejectingOutliers()
    }

    /// Shows the dot gliding across the display, and returns the frames while the eyes followed
    /// it, each labeled with where the dot was, in short stretches.
    private func follow(_ kind: PursuitPath.Kind, on display: CGRect, displayIndex: Int) async throws -> [Collected] {
        isCollecting = false
        headTurnStart = nil
        target = Target(point: PursuitPath.point(kind, in: display, at: 0), displayIndex: displayIndex, moveHead: false)
        stageStep += 1
        try await Task.sleep(for: .milliseconds(1200))
        let path = Pursuit(kind: kind, display: display, displayIndex: displayIndex, start: CACurrentMediaTime())
        buffer = []
        arrivals = []
        pursuit = path
        isCollecting = true
        defer { isCollecting = false }
        try await Task.sleep(for: .seconds(path.duration))
        pursuit = nil
        target = Target(point: path.point(at: path.start + path.duration), displayIndex: displayIndex, moveHead: false)

        let time = bufferClock(since: path.start)
        let followed = buffer.filter { time($0) >= Pursuit.settle && time($0) <= path.duration }
        let segments = Dictionary(grouping: followed) { Int(time($0) / Pursuit.segment) }
        return segments.keys.sorted().compactMap { key in
            // Catch-up saccades and lapses show up as frames far from their stretch's trend.
            let frames = segments[key]!.rejectingOutliers()
            guard frames.count >= 3 else { return nil }
            return Collected(displayIndex: displayIndex, moveHead: false, frames: frames.map { ($0, path.point(at: path.start + time($0) - Pursuit.lag)) })
        }
    }

    /// Shows a resting dot to hold the eyes on while turning the head, and returns the frames in
    /// short stretches, like a pursuit's, so each head pose counts on its own.
    private func turnHead(at next: Target) async throws -> [Collected] {
        isCollecting = false
        target = next
        // The arrow starts circling as the dot appears, so the head is already moving when frames count.
        headTurnStart = CACurrentMediaTime()
        stageStep += 1
        try await Task.sleep(for: .milliseconds(1000))
        let start = CACurrentMediaTime()
        buffer = []
        arrivals = []
        isCollecting = true
        defer { isCollecting = false }
        try await Task.sleep(for: .seconds(Self.headMotionDuration))
        isCollecting = false

        let time = bufferClock(since: start)
        let segments = Dictionary(grouping: buffer.filter { time($0) >= 0 }) { Int(time($0) / Pursuit.segment) }
        return segments.keys.sorted().compactMap { key in
            // The head turns slowly, so within a stretch eye angles stay close; glances stand out.
            let frames = segments[key]!.rejectingOutliers()
            guard frames.count >= 3 else { return nil }
            return Collected(displayIndex: next.displayIndex, moveHead: true, frames: frames.map { ($0, next.point) })
        }
    }

    /// Seconds since `start` for a buffered frame. Camera frames are stamped with the host clock,
    /// like `CACurrentMediaTime()`. Should a camera use another clock, its frames are moved onto
    /// ours by when they arrived.
    private func bufferClock(since start: TimeInterval) -> (FaceSample) -> TimeInterval {
        let offsets = zip(buffer, arrivals).map { $1 - $0.timestamp }
        let offset = offsets.isEmpty || abs(median(offsets)) < 1 ? 0 : median(offsets)
        return { $0.timestamp + offset - start }
    }

    // MARK: Targets

    /// A 3×3 grid, then a few targets to hold while moving the head, which teaches the model how
    /// head motion and eye motion combine.
    static func calibrationTargets(on frame: CGRect, displayIndex: Int) -> [Target] {
        let grid: [(Double, Double)] = [
            (0.06, 0.94), (0.5, 0.94), (0.94, 0.94),
            (0.94, 0.5), (0.5, 0.5), (0.06, 0.5),
            (0.06, 0.06), (0.5, 0.06), (0.94, 0.06),
        ]
        let moving: [(Double, Double)] = [(0.5, 0.5), (0.2, 0.25), (0.8, 0.75)]
        return grid.map { Target(point: point(in: frame, $0), displayIndex: displayIndex, moveHead: false) }
            + moving.map { Target(point: point(in: frame, $0), displayIndex: displayIndex, moveHead: true) }
    }

    static func validationTargets(on frame: CGRect, displayIndex: Int) -> [Target] {
        let still: [(Double, Double)] = [(0.2, 0.8), (0.8, 0.8), (0.5, 0.6), (0.8, 0.2), (0.2, 0.2)]
        let moving: [(Double, Double)] = [(0.35, 0.4), (0.65, 0.6)]
        return still.map { Target(point: point(in: frame, $0), displayIndex: displayIndex, moveHead: false) }
            + moving.map { Target(point: point(in: frame, $0), displayIndex: displayIndex, moveHead: true) }
    }

    /// `relative` is (x, y) from the top-left, which reads more naturally than AppKit's bottom-left.
    private static func point(in frame: CGRect, _ relative: (Double, Double)) -> CGPoint {
        CGPoint(x: frame.minX + frame.width * relative.0, y: frame.maxY - frame.height * relative.1)
    }

    // MARK: Windows

    private func showWindows(displays: [DisplayInfo]) {
        for (index, display) in displays.enumerated() {
            let window = OverlayWindow.make(
                covering: display.frame,
                interactive: true,
                content: CalibrationOverlayView(screenFrame: display.frame, isPrimary: index == 0, controller: self)
            )
            window.onKeyDown = { [weak self] event in
                switch event.keyCode {
                case 53: self?.close() // Escape
                case 49, 36: self?.begin() // Space, Return
                default: break
                }
            }
            window.orderFrontRegardless()
            windows.append(window)
        }
        windows.first?.makeKey()
        NSApp.activate()
        NSCursor.hide()
    }
}

private struct CalibrationOverlayView: View {
    let screenFrame: CGRect
    let isPrimary: Bool
    let controller: CalibrationController

    var body: some View {
        ZStack {
            // Light rather than dark: the screen lights the face for the camera, and most of what's
            // on screen day to day is light too, so the eyes look as they will when tracked.
            Color.white.opacity(0.9)

            if controller.announcedAt == nil {
                dot
            }

            if isPrimary {
                content
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(Color.gazeInk)
        .environment(\.colorScheme, .light)
    }

    // MARK: Dot

    @ViewBuilder
    private var dot: some View {
        if let pursuit = controller.pursuit, pursuit.display == screenFrame {
            TimelineView(.animation) { _ in
                let point = pursuit.point(at: CACurrentMediaTime())
                CalibrationDot(isCollecting: true)
                    .position(local(point))
            }
        } else if let target = controller.target, screenFrame.contains(target.point) {
            let position = local(target.point)
            ZStack {
                if target.moveHead, let start = controller.headTurnStart {
                    HeadCircleCue(start: start)
                        .position(position)
                    Text("Keep looking at the dot · move your head in a circle with the arrow")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.gazeInk.opacity(0.55))
                        .fixedSize()
                        .position(x: min(max(position.x, 300), screenFrame.width - 300), y: position.y + (position.y > screenFrame.height - 140 ? -62 : 62))
                }
                CalibrationDot(isCollecting: controller.isCollecting)
                    .position(position)
            }
            .animation(.easeInOut(duration: 0.35), value: target.point)
        }
    }

    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
    }

    // MARK: Cards and progress

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .intro:
            IntroCard(controller: controller)
        case .calibrating, .validating, .fitting:
            if let stage = controller.stage, let announcedAt = controller.announcedAt {
                StageCard(stage: stage, announcedAt: announcedAt)
            } else if controller.phase == .fitting {
                CalibrationCard {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Computing calibration…").font(.title3.weight(.medium))
                    }
                }
            }
            VStack {
                Spacer()
                ProgressStrip(controller: controller)
                    .padding(.bottom, 28)
            }
        case .finished(let report):
            ResultCard(report: report, close: controller.close)
        case .failed(let message):
            CalibrationCard {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text("Calibration failed").font(.title.weight(.semibold))
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.gazeInk.opacity(0.65))
                    Button("Close", action: controller.close)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
            .onAppear { NSCursor.unhide() }
        }
    }
}

/// A white card floating on the light overlay.
private struct CalibrationCard<Content: View>: View {
    var width: CGFloat = 560
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(36)
            .frame(width: width)
            .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.gazeInk.opacity(0.06)))
            .shadow(color: .black.opacity(0.12), radius: 32, y: 12)
    }
}

private struct IntroCard: View {
    let controller: CalibrationController

    private static let summaries: [CalibrationController.Stage: String] = [
        .dots: "Look at a dozen dots, one at a time",
        .follow: "Follow a gliding dot with your eyes",
        .followAgain: "Shift how you sit, then follow it again",
        .turnHead: "Look at a dot while circling your head",
        .check: "A few dots to measure accuracy",
    ]

    var body: some View {
        CalibrationCard(width: 600) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    GazeMark()
                        .foregroundStyle(Color.gazeMintDeep)
                        .frame(width: 40, height: 40)
                    Text("Calibrate Gaze")
                        .font(.largeTitle.weight(.bold))
                    Text("About 2½ minutes. Sit as you usually do, at your usual distance from the screen. Each step explains itself before it starts.")
                        .foregroundStyle(Color.gazeInk.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(CalibrationController.Stage.allCases, id: \.self) { stage in
                        HStack(spacing: 14) {
                            Image(systemName: stage.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color.gazeMintDeep)
                                .frame(width: 34, height: 34)
                                .background(Color.gazeMint.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stage.title).font(.body.weight(.semibold))
                                Text(Self.summaries[stage] ?? "")
                                    .font(.callout)
                                    .foregroundStyle(Color.gazeInk.opacity(0.6))
                            }
                        }
                    }
                }
                FaceStatus(controller: controller)
                HStack(spacing: 6) {
                    Keycap("Space")
                    Text("to start")
                    Spacer()
                    Keycap("Esc")
                    Text("to cancel")
                }
                .font(.callout)
                .foregroundStyle(Color.gazeInk.opacity(0.6))
            }
        }
    }
}

/// Whether the camera sees the face, checked live.
private struct FaceStatus: View {
    let controller: CalibrationController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let sees = controller.seesFace
            HStack(spacing: 8) {
                Image(systemName: sees ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(sees ? Color.gazeMintDeep : .orange)
                Text(sees ? "The camera sees your face" : "The camera can't see your face yet. Check the lighting, and that nothing covers the camera.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((sees ? Color.gazeMint.opacity(0.14) : Color.orange.opacity(0.12)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.gazeInk.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.gazeInk.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gazeInk.opacity(0.15)))
    }
}

/// What the next stage asks, with a countdown to its first dot.
private struct StageCard: View {
    let stage: CalibrationController.Stage
    let announcedAt: TimeInterval

    var body: some View {
        CalibrationCard {
            VStack(spacing: 18) {
                Image(systemName: stage.symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.gazeMintDeep)
                    .frame(width: 64, height: 64)
                    .background(Color.gazeMint.opacity(0.18), in: Circle())
                VStack(spacing: 8) {
                    Text("Step \(stage.rawValue + 1) of \(CalibrationController.Stage.allCases.count)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.gazeMintDeep)
                    Text(stage.title)
                        .font(.title.weight(.bold))
                    Text(stage.instruction)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.gazeInk.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                TimelineView(.animation) { _ in
                    let elapsed = CACurrentMediaTime() - announcedAt
                    let remaining = max(0, CalibrationController.announceDuration - elapsed)
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().stroke(Color.gazeInk.opacity(0.1), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: remaining / CalibrationController.announceDuration)
                                .stroke(Color.gazeMintDeep, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 22, height: 22)
                        Text("Starting in \(Int(remaining.rounded(.up)))")
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.gazeInk.opacity(0.55))
                    }
                }
            }
        }
    }
}

/// The stages along the bottom, the current one's progress, and a warning when the face is lost.
private struct ProgressStrip: View {
    let controller: CalibrationController

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                if !controller.seesFace {
                    Label("Face not detected", systemImage: "exclamationmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 6) {
                ForEach(CalibrationController.Stage.allCases, id: \.self) { stage in
                    pill(stage)
                }
            }
        }
    }

    private func pill(_ stage: CalibrationController.Stage) -> some View {
        let current = controller.stage
        let isCurrent = stage == current
        let isDone = current.map { stage.rawValue < $0.rawValue } ?? false
        return VStack(spacing: 5) {
            HStack(spacing: 5) {
                if isDone {
                    Image(systemName: "checkmark").font(.caption.weight(.bold))
                }
                Text(stage.shortTitle)
            }
            .font(.caption.weight(isCurrent ? .semibold : .medium))
            .foregroundStyle(isCurrent ? Color.gazeInk : Color.gazeInk.opacity(isDone ? 0.55 : 0.35))
            Capsule()
                .fill(Color.gazeInk.opacity(0.08))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.gazeMintDeep)
                            .frame(width: geo.size.width * fraction(stage, isCurrent: isCurrent, isDone: isDone))
                    }
                }
                .frame(width: 84, height: 4)
                .animation(.easeOut(duration: 0.3), value: controller.stageStep)
        }
    }

    private func fraction(_ stage: CalibrationController.Stage, isCurrent: Bool, isDone: Bool) -> Double {
        if isDone { return 1 }
        guard isCurrent, controller.stageStepCount > 0, controller.announcedAt == nil else { return 0 }
        return Double(controller.stageStep) / Double(controller.stageStepCount)
    }
}

/// A small arrow circling a dot: where to move the head while the eyes stay on the dot. It stays
/// close to the dot so following it doesn't pull the eyes away.
private struct HeadCircleCue: View {
    let start: TimeInterval
    static let radius: CGFloat = 30

    var body: some View {
        TimelineView(.animation) { _ in
            // Clockwise from the top.
            let angle = 2 * Double.pi * (CACurrentMediaTime() - start) / CalibrationController.headCirclePeriod
            ZStack {
                Circle()
                    .stroke(Color.gazeInk.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                    .frame(width: Self.radius * 2, height: Self.radius * 2)
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.gazeMintDeep)
                    .rotationEffect(.radians(angle))
                    .offset(x: Self.radius * sin(angle), y: -Self.radius * cos(angle))
            }
        }
    }
}

private struct CalibrationDot: View {
    let isCollecting: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gazeInk.opacity(0.35), lineWidth: 2)
                .frame(width: isCollecting ? 16 : 40, height: isCollecting ? 16 : 40)
            Circle()
                .fill(isCollecting ? Color.gazeMintDeep : Color.gazeInk)
                .frame(width: 9, height: 9)
        }
        .animation(.easeOut(duration: 0.6), value: isCollecting)
    }
}

private struct ResultCard: View {
    let report: ValidationReport
    let close: () -> Void

    var body: some View {
        CalibrationCard(width: 480) {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.gazeMintDeep)
                VStack(spacing: 4) {
                    Text("Calibration complete").font(.title.weight(.bold))
                    Text(report.meanErrorMillimeters.isNaN ? "–" : String(format: "Off by about %.0f mm on average", report.meanErrorMillimeters))
                        .font(.title3)
                        .foregroundStyle(Color.gazeInk.opacity(0.65))
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Head still", report.stillErrorMillimeters)
                    row("Head moving", report.movingErrorMillimeters)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row("Overall", report.meanErrorMillimeters)
                }
                .padding(16)
                .background(Color.gazeInk.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let alternatives = report.alternatives, !alternatives.isEmpty {
                    VStack(spacing: 4) {
                        Text("Using \(report.gazeSource.label.lowercased()). Compared with:")
                        ForEach(alternatives, id: \.gazeSource) { alternative in
                            Text(String(format: "%@: %.0f mm still · %.0f mm moving", alternative.gazeSource.label, alternative.stillErrorMillimeters, alternative.movingErrorMillimeters))
                                .monospacedDigit()
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(Color.gazeInk.opacity(0.6))
                }
                Text("Degrees assume a viewing distance of \(Int(ValidationReport.assumedViewingDistanceMM / 10)) cm.")
                    .font(.caption)
                    .foregroundStyle(Color.gazeInk.opacity(0.5))
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .onAppear { NSCursor.unhide() }
    }

    private func row(_ label: String, _ millimeters: Double) -> some View {
        GridRow {
            Text(label)
            Text(millimeters.isNaN ? "–" : String(format: "%.0f mm · %.1f°", millimeters, report.degrees(millimeters)))
                .monospacedDigit()
        }
    }
}
