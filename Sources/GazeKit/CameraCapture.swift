@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    public var errorDescription: String? {
        switch self {
        case .noCamera: "No camera found."
        case .cannotAddInput: "Could not open the camera."
        case .cannotAddOutput: "Could not read frames from the camera."
        }
    }
}

/// Streams camera frames through a `FaceAnalyzer` on a private serial queue.
public final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public struct Device: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
    }

    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "gaze.camera", qos: .userInteractive)
    private let analyzer = FaceAnalyzer()
    private var onSample: (@Sendable (FrameAnalysis, TimeInterval) -> Void)?
    private var device: AVCaptureDevice?
    /// When a face was last seen, and whether the camera is idling at a low frame rate.
    private var lastFaceTime: TimeInterval?
    private var isIdling = false
    /// The frame rate while a face is in view; `nil` is the camera's own (30 on Mac cameras).
    private var frameRate: Int32?
    /// With nobody in front of the camera, analyzing 30 frames a second is wasted; a few still
    /// notice someone sitting down within a fraction of a second.
    static let idleAfter: TimeInterval = 3
    static let idleFrameRate: Int32 = 5

    public static func availableDevices() -> [Device] {
        discovery().devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
    }

    /// Configures the session and starts streaming. `onSample` is called on the camera queue
    /// for every frame.
    public func start(deviceID: String? = nil, onSample: @escaping @Sendable (FrameAnalysis, TimeInterval) -> Void) throws {
        let devices = Self.discovery().devices
        let device = devices.first { $0.uniqueID == deviceID }
            ?? devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first
        guard let device else { throw CameraError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        // More pixels across the eye gives a steadier iris estimate.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)

        self.onSample = onSample
        self.device = device
        lastFaceTime = nil
        isIdling = false
        let session = session
        queue.async { [self] in
            session.startRunning()
            if frameRate != nil, (try? device.lockForConfiguration()) != nil {
                applyActiveFrameRate(device)
                device.unlockForConfiguration()
            }
        }
    }

    /// The camera's field of view, the user's face shape, the gaze source, and the user's
    /// correction of the network, as calibrated. While calibrating, the camera is seen with the
    /// field of view the new calibration will have, and the network runs the way new calibrations
    /// use it, whatever the current model was calibrated with.
    public func setGeometry(for model: GazeModel?, calibrating: Bool, calibrationFieldOfView: Double = GazeModel.defaultFieldOfView) {
        analyzer.geometry = (
            calibrating ? calibrationFieldOfView : model?.fieldOfView ?? GazeModel.defaultFieldOfView,
            model?.faceShape ?? .generic,
            model?.gazeSource ?? .iris,
            model?.featureCorrection,
            calibrating || (model?.averagesMirroredNetwork ?? true)
        )
    }

    /// Runs the camera at `rate` frames a second while a face is in view (`nil`: the camera's own
    /// rate). Fewer frames cost proportionally less of the face detection and the network.
    public func setFrameRate(_ rate: Int32?) {
        queue.async { [self] in
            frameRate = rate
            guard !isIdling, let device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            applyActiveFrameRate(device)
        }
    }

    /// Sets the full-speed frame rate. The caller holds the device's configuration lock.
    private func applyActiveFrameRate(_ device: AVCaptureDevice) {
        if let frameRate, device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(frameRate) && Double(frameRate) <= $0.maxFrameRate }) {
            let duration = CMTime(value: 1, timescale: frameRate)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } else {
            // Invalid restores the format's default frame rate.
            device.activeVideoMinFrameDuration = .invalid
            device.activeVideoMaxFrameDuration = .invalid
        }
    }

    public func setCapturesFaceImages(_ enabled: Bool) {
        analyzer.capturesFaceImages = enabled
    }

    public func stop() {
        let session = session
        queue.async { session.stopRunning() }
    }

    /// Starts a stopped session again, as configured.
    public func resume() {
        let session = session
        queue.async { session.startRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let analysis = analyzer.analyze(pixelBuffer, timestamp: timestamp)
        adjustFrameRate(faceFound: analysis.sample != nil, at: timestamp)
        onSample?(analysis, timestamp)
    }

    /// Idles at a low frame rate while no face is in view, and returns to full speed on the first face.
    private func adjustFrameRate(faceFound: Bool, at timestamp: TimeInterval) {
        if faceFound || lastFaceTime == nil { lastFaceTime = timestamp }
        let idle = !faceFound && timestamp - (lastFaceTime ?? timestamp) > Self.idleAfter
        guard idle != isIdling, let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if idle {
            let rate = Double(Self.idleFrameRate)
            guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= rate && rate <= $0.maxFrameRate }) else { return }
            let duration = CMTime(value: 1, timescale: Self.idleFrameRate)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } else {
            applyActiveFrameRate(device)
        }
        isIdling = idle
    }
}
