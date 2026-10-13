import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// Owns the camera pipeline and turns face samples into a smoothed on-screen gaze point.
@MainActor
@Observable
public final class GazeEngine {
    public typealias SampleObserver = @MainActor (FaceSample) -> Void

    public private(set) var isRunning = false
    /// Stopped for now by `pause()`.
    public private(set) var isPaused = false
    public private(set) var cameraError: String?
    /// Frame rate, updated once a second so views showing it don't redraw every frame.
    public private(set) var fps: Double = 0
    /// Every frame; only views that show live tracking should read it, since reading it redraws them per frame.
    public private(set) var latestSample: FaceSample?
    /// `latestSample` at most 15 times a second, for views that show it: plenty to watch, at half
    /// the redraws.
    public private(set) var displayedSample: FaceSample?
    /// Whether a face is being tracked, for views that only need to know that.
    public private(set) var hasFace = false
    /// Why tracking is degraded or lost right now, if it is.
    public private(set) var trackingIssue: TrackingIssue?
    /// Unfiltered prediction in global screen coordinates.
    public private(set) var rawGaze: CGPoint?
    /// Stabilized prediction in global screen coordinates: steady while the eyes rest on a spot.
    public private(set) var gaze: CGPoint?

    public var model: GazeModel? {
        didSet {
            camera.setGeometry(for: model, calibrating: isCalibrating, calibrationFieldOfView: calibrationFieldOfView)
            stabilizer.reset()
        }
    }

    /// Set while calibrating, so the samples are measured the way a new model will use them.
    public var isCalibrating = false {
        didSet {
            camera.setGeometry(for: model, calibrating: isCalibrating, calibrationFieldOfView: calibrationFieldOfView)
            applyFrameRate()
        }
    }

    /// The camera's horizontal field of view a new calibration uses. The current model keeps the
    /// one it was calibrated with: its face shape and personalization were fitted to it.
    public var calibrationFieldOfView = GazeModel.defaultFieldOfView {
        didSet { if isCalibrating { camera.setGeometry(for: model, calibrating: true, calibrationFieldOfView: calibrationFieldOfView) } }
    }

    public var displays: [DisplayInfo] = []

    /// Attach a JPEG of the face to each sample, for recording calibration data.
    public var capturesFaceImages = false {
        didSet { camera.setCapturesFaceImages(capturesFaceImages) }
    }

    /// Tracks at 15 frames a second instead of 30: about half the processing, with the gaze point
    /// a little slower to follow the eyes. Calibration always runs at full speed, for more frames.
    public var lightTracking = false {
        didSet { if lightTracking != oldValue { applyFrameRate() } }
    }

    private func applyFrameRate() {
        camera.setFrameRate(lightTracking && !isCalibrating ? 15 : nil)
    }

    /// 0 = most responsive, 1 = steadiest.
    public var smoothing: Double = 0.6 {
        didSet { stabilizer.steadiness = smoothing }
    }

    @ObservationIgnored private let camera = CameraCapture()
    @ObservationIgnored private var stabilizer = GazeStabilizer(steadiness: 0.6)
    @ObservationIgnored private var observers: [UUID: SampleObserver] = [:]
    @ObservationIgnored private var lastFrameTime: TimeInterval?
    @ObservationIgnored private var measuredFPS: Double = 0
    @ObservationIgnored private var lastFPSUpdate: TimeInterval = 0
    @ObservationIgnored private var lastDisplayedTime: TimeInterval = 0
    /// The previous frame that went into the gaze point, for measuring head motion between frames.
    @ObservationIgnored private var previousHead: FaceSample?
    /// The last moments of tracked frames, so an interaction can look back at where the eyes were.
    @ObservationIgnored private var history: [FaceSample] = []
    /// Smallest seen gap between system uptime and frame timestamps.
    @ObservationIgnored private var clockOffset: Double?

    public init() {}

    public func start() async {
        guard !isRunning else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            cameraError = "Camera access denied. Enable it in System Settings › Privacy & Security › Camera."
            return
        }
        do {
            try camera.start { [weak self] analysis, timestamp in
                Task { @MainActor in self?.handle(analysis, at: timestamp) }
            }
            cameraError = nil
            isRunning = true
        } catch {
            cameraError = error.localizedDescription
        }
    }

    public func stop() {
        camera.stop()
        isRunning = false
        latestSample = nil
        displayedSample = nil
        hasFace = false
        rawGaze = nil
        gaze = nil
    }

    /// Stops the camera while nobody can be using the Mac (screen locked or asleep), so it
    /// costs nothing and the camera light goes off. `resume()` picks up where it left off.
    public func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        camera.stop()
        latestSample = nil
        displayedSample = nil
        hasFace = false
        rawGaze = nil
        gaze = nil
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        stabilizer.reset()
        previousHead = nil
        camera.resume()
    }

    /// Registers a callback for every usable (face found, eyes open) frame.
    public func addSampleObserver(_ observer: @escaping SampleObserver) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeSampleObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// Frames captured between two moments given in system uptime (the clock of `NSEvent.timestamp`).
    public func frames(from start: TimeInterval, to end: TimeInterval) -> [FaceSample] {
        // Camera timestamps normally share the uptime clock; if not, map them via the observed offset.
        let offset = clockOffset.map { abs($0) < 1 ? 0 : $0 } ?? 0
        return history.filter { (start...end).contains($0.timestamp + offset) }
    }

    private func handle(_ analysis: FrameAnalysis, at timestamp: TimeInterval) {
        let sample = analysis.sample
        // Observation notifies on every assignment, equal or not, and each notification redraws
        // the views that read the property. Only assign what changed.
        if trackingIssue != analysis.issue { trackingIssue = analysis.issue }
        if let lastFrameTime, timestamp > lastFrameTime {
            let instant = 1 / (timestamp - lastFrameTime)
            measuredFPS = measuredFPS == 0 ? instant : measuredFPS * 0.9 + instant * 0.1
            if timestamp - lastFPSUpdate >= 1 {
                fps = measuredFPS
                lastFPSUpdate = timestamp
            }
        }
        lastFrameTime = timestamp

        latestSample = sample
        if timestamp - lastDisplayedTime >= 1.0 / 15 || (sample == nil) != (displayedSample == nil) {
            displayedSample = sample
            lastDisplayedTime = timestamp
        }
        if hasFace != (sample != nil) { hasFace = sample != nil }
        let offset = ProcessInfo.processInfo.systemUptime - timestamp
        clockOffset = min(clockOffset ?? offset, offset)
        if let sample {
            history.append(sample)
            history.removeAll { $0.timestamp < timestamp - 1.5 }
        }
        // Hold the last gaze point through blinks rather than jumping on closed-eye frames.
        guard let sample, !sample.isBlinking else { return }

        for observer in observers.values {
            observer(sample)
        }

        guard let model else {
            if rawGaze != nil { rawGaze = nil }
            if gaze != nil { gaze = nil }
            return
        }
        guard let predicted = model.predict(sample.observation) else { return }
        let point = displays.clamp(predicted)
        rawGaze = point
        // The stabilizer holds still while the eyes rest, so this mostly doesn't change.
        let steady = stabilizer.update(point, headShift: headShift(to: sample, model: model, predicted: predicted), at: timestamp)
        if gaze != steady { gaze = steady }
        previousHead = sample
    }

    /// How far the gaze point moved since the previous frame from head motion alone: the same eye
    /// angles from the previous head position and rotation. Iris noise mostly cancels out of this,
    /// so it's a precise measure of what the head did.
    private func headShift(to sample: FaceSample, model: GazeModel, predicted: CGPoint) -> CGVector {
        guard let previous = previousHead, sample.timestamp - previous.timestamp < 0.2 else { return .zero }
        var before = sample.observation
        before.origin = previous.observation.origin
        before.headRotation = previous.observation.headRotation
        guard let from = model.predict(before) else { return .zero }
        return CGVector(dx: predicted.x - from.x, dy: predicted.y - from.y)
    }
}
