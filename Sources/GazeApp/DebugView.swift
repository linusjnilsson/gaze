import GazeKit
import simd
import SwiftUI

/// Live view of what the tracker sees: landmarks, iris position within each eye, and raw features.
struct DebugView: View {
    @Environment(AppModel.self) private var model
    /// Off while the window is minimized, hidden or fully covered: the live view then doesn't
    /// read the per-frame sample, so it doesn't redraw 30 times a second for nobody.
    @State private var isVisible = true

    var body: some View {
        let engine = model.engine
        let latestSample = isVisible ? engine.displayedSample : nil

        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 12) {
                FaceCanvas(sample: latestSample)
                    .frame(width: 360, height: 270)
                    .background(.black, in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 12) {
                    // Mirrored like a selfie view.
                    EyeCanvas(title: "Left eye", eye: latestSample?.leftEye)
                    EyeCanvas(title: "Right eye", eye: latestSample?.rightEye)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Frame rate", String(format: "%.1f fps", engine.fps))
                    row("Face", latestSample == nil ? "not found" : (latestSample!.isBlinking ? "blinking" : "tracked"))
                    row("Gaze", engine.gaze.map { String(format: "%.0f, %.0f", $0.x, $0.y) } ?? "–")
                    Divider().gridCellUnsizedAxes(.horizontal)
                    if let sample = latestSample {
                        let t = sample.head.translation
                        let head = Rotation.headAngles(sample.head.rotation) * 180 / .pi
                        let eye = sample.observation.eyeAngles * 180 / .pi
                        // Camera x is the user's left, so flip it to read as the user sees it.
                        row("Head position", String(format: "%+.0f, %+.0f mm", -t.x, t.y))
                        row("Distance", String(format: "%.0f cm", simd_length(t) / 10))
                        row("Head yaw/pitch", String(format: "%+.0f°, %+.0f°", -head.x, head.y))
                        row("Head roll", String(format: "%+.0f°", head.z))
                        row("Eye yaw/pitch", String(format: "%+.1f°, %+.1f°", -eye.x, eye.y))
                        if let network = sample.measurements.networkGaze {
                            let angles = sample.observation.withGaze(network).eyeAngles * 180 / .pi
                            row("Network yaw/pitch", String(format: "%+.1f°, %+.1f°", -angles.x, angles.y))
                        }
                    }
                    row("Gaze network", GazeNetwork.isInstalled ? (latestSample?.measurements.networkGaze == nil ? "installed" : "running") : "not installed")
                    if let model = model.engine.model {
                        row("Tracking with", model.gazeSource.label.lowercased() + (model.featureCorrection == nil ? "" : ", personalized"))
                        row("Face shape", model.face == nil ? "generic" : "learned")
                    }
                }
                .font(.system(.body, design: .monospaced))

                Divider()

                LearningStats(learner: model.learner, corrections: model.engine.model?.corrections?.count ?? 0)

                Divider()

                Text("Displays").font(.headline)
                ForEach(model.displays, id: \.displayID) { display in
                    Text("\(display.name) — \(Int(display.frame.width))×\(Int(display.frame.height)) pt at (\(Int(display.frame.minX)), \(Int(display.frame.minY)))")
                        .font(.caption)
                }
                Text("Profile \(model.signature)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 480)
        .background(WindowVisibilityReader(isVisible: $isVisible))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// When learning happened this session, and why other interactions were skipped.
private struct LearningStats: View {
    let learner: InteractionLearner
    let corrections: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Learning this session").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                GridRow {
                    Text("Learned from").foregroundStyle(.secondary)
                    Text("\(learner.acceptedThisSession)").monospacedDigit()
                }
                ForEach(InteractionLearner.SkipReason.allCases, id: \.self) { reason in
                    if let count = learner.skipped[reason] {
                        GridRow {
                            Text("Skipped: \(reason.rawValue)").foregroundStyle(.secondary)
                            Text("\(count)").monospacedDigit()
                        }
                    }
                }
                GridRow {
                    Text("Correction layers").foregroundStyle(.secondary)
                    Text(corrections == 0 ? "none yet" : "\(corrections) display\(corrections == 1 ? "" : "s")")
                }
            }
            .font(.caption)
        }
    }
}

private struct FaceCanvas: View {
    let sample: FaceSample?

    var body: some View {
        Canvas { context, size in
            guard let sample else { return }
            // Normalized Vision coordinates → canvas, mirrored like a selfie view.
            func map(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (1 - p.x) * size.width, y: (1 - p.y) * size.height)
            }
            let box = sample.faceBox
            let faceRect = CGRect(
                x: (1 - box.maxX) * size.width,
                y: (1 - box.maxY) * size.height,
                width: box.width * size.width,
                height: box.height * size.height
            )
            context.stroke(Path(roundedRect: faceRect, cornerRadius: 6), with: .color(.white.opacity(0.4)))

            for eye in [sample.leftEye, sample.rightEye] {
                var path = Path()
                path.addLines(eye.contour.map(map))
                path.closeSubpath()
                context.stroke(path, with: .color(.cyan), lineWidth: 1)
                let iris = map(eye.iris)
                context.fill(Path(ellipseIn: CGRect(x: iris.x - 2.5, y: iris.y - 2.5, width: 5, height: 5)), with: .color(eye.irisRefined ? .green : .yellow))
            }

            // Landmarks the head-pose fit is using; nose and mouth disappear when out of view.
            let m = sample.measurements
            for point in m.landmarks.compactMap({ $0 }) {
                let p = map(CGPoint(x: point.x / m.imageSize.x, y: point.y / m.imageSize.y))
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.orange), lineWidth: 1)
            }
        }
        .overlay {
            if sample == nil {
                Text("No face").foregroundStyle(.secondary)
            }
        }
    }
}

/// The eye in its own corner-aligned frame, scaled up, so small iris movements are visible.
private struct EyeCanvas: View {
    let title: String
    let eye: EyeSample?

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                guard let eye else { return }
                // u: -0.1…1.1 across, v: -0.35…0.35 tall, mirrored horizontally.
                func map(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: (1.1 - p.x) / 1.2 * size.width, y: (0.35 - p.y) / 0.7 * size.height)
                }
                var path = Path()
                path.addLines(eye.contourUV.map(map))
                path.closeSubpath()
                context.stroke(path, with: .color(.cyan), lineWidth: 1.5)
                let iris = map(eye.irisUV)
                context.fill(Path(ellipseIn: CGRect(x: iris.x - 6, y: iris.y - 6, width: 12, height: 12)), with: .color(eye.irisRefined ? .green : .yellow))
            }
            .frame(width: 174, height: 100)
            .background(.black, in: RoundedRectangle(cornerRadius: 8))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Reports whether the hosting window can be seen at all (not minimized, hidden or fully covered).
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            onChange?(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}
