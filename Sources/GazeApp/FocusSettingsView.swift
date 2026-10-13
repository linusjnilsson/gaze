import GazeKit
import SwiftUI

/// Advanced settings: the camera's field of view, and for focus switching what the window trigger
/// may do, how sure a pick must be, timing, and the pointer jump.
struct FocusSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let defaults = FocusTuning()

        Form {
            CameraSection()

            Section {
                Toggle(isOn: $model.focusTuning.revealsHidden) {
                    Text("Bring back windows hidden behind the focused one")
                    Text("Looking at the window that already has focus picks what's hidden behind it at that spot. Off, the trigger there does nothing, and only windows you can see can be picked.")
                }
                Toggle(isOn: $model.focusTuning.outlinesBuried) {
                    Text("Outline hidden windows while holding")
                    Text("Dashed outlines of the windows directly behind the focused one.")
                }
                .disabled(!model.focusTuning.revealsHidden)
                Toggle(isOn: $model.focusTuning.labelsBuried) {
                    Text("Name tags on those outlines")
                }
                .disabled(!model.focusTuning.revealsHidden || !model.focusTuning.outlinesBuried)
            } header: {
                Text("Window trigger")
            }

            Section {
                TuningSlider(
                    title: "Gaze blur", value: $model.focusTuning.blurScale, range: 0.5...1.5, step: 0.05,
                    format: { String(format: "%.2f×", $0) },
                    help: "How wide the gaze is treated, relative to the measured tracking error. Narrower picks closer to borders, but trusts the gaze more than it deserves."
                )
                TuningSlider(
                    title: "Lead over the runner-up", value: $model.focusTuning.minimumLead, range: 1.05...2.5, step: 0.05,
                    format: { String(format: "%.2f×", $0) },
                    help: "How much more of the gaze the picked window must hold than the next one. Lower is more forgiving near borders and stacks; higher refuses more often but picks wrong less."
                )
                TuningSlider(
                    title: "Share of the gaze", value: $model.focusTuning.minimumShare, range: 0.15...0.7, step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) },
                    help: "How much of the blur a window needs at least. Lower lets small windows be picked."
                )
                TuningSlider(
                    title: "Outline stickiness", value: $model.focusTuning.switchLead, range: 1.0...3.0, step: 0.1,
                    format: { String(format: "%.1f×", $0) },
                    help: "While holding, how far another window must lead to take over the outline. Higher keeps it steady between windows."
                )
                TuningSlider(
                    title: "Gaze averaging", value: $model.focusTuning.averagingTime, range: 0.03...0.8, step: 0.03,
                    format: { String(format: "%.2f s", $0) },
                    help: "How much of the gaze since the key went down is averaged. Longer is steadier, shorter follows the eyes faster."
                )
            } header: {
                Text("Picking")
            }

            Section {
                Toggle(isOn: $model.focusTuning.switchesDisplays) {
                    Text("Switch displays by looking")
                    Text("Look at another display for a moment and focus moves there, to the window you last used on it, with the pointer. No key needed.")
                }
                TuningSlider(
                    title: "Look this long", value: $model.focusTuning.displayDwell, range: 0.15...1.5, step: 0.05,
                    format: { String(format: "%.2f s", $0) },
                    help: "How long the gaze rests on the other display, well clear of the bezel, before focus moves. Longer ignores quick glances."
                )
                .disabled(!model.focusTuning.switchesDisplays)
                TuningSlider(
                    title: "Pause after typing", value: $model.focusTuning.typingPause, range: 0.5...6, step: 0.5,
                    format: { String(format: "%.1f s", $0) },
                    help: "Focus stays put this long after a keystroke, so glancing at notes on another display while typing doesn't take your keystrokes there."
                )
                .disabled(!model.focusTuning.switchesDisplays)
                TuningSlider(
                    title: "Pause after the mouse", value: $model.focusTuning.mousePause, range: 0.5...5, step: 0.5,
                    format: { String(format: "%.1f s", $0) },
                    help: "Focus stays put this long after moving the mouse, scrolling or clicking."
                )
                .disabled(!model.focusTuning.switchesDisplays)
            } header: {
                Text("Displays")
            } footer: {
                if model.displays.count < 2 {
                    Text("Only one display is connected.")
                }
            }

            Section {
                TuningSlider(
                    title: "Outline delay", value: $model.focusTuning.previewDelay, range: 0...0.5, step: 0.05,
                    format: { String(format: "%.2f s", $0) },
                    help: "How long the trigger is held before the outline shows. Shorter shows it sooner, but quick taps flash it."
                )
                TuningSlider(
                    title: "Overview ⇧ hold", value: $model.focusTuning.overviewDelay, range: 0.1...0.8, step: 0.05,
                    format: { String(format: "%.2f s", $0) },
                    help: "How long ⇧ is held with the trigger before the overview opens (a tap opens it at once)."
                )
            } header: {
                Text("Timing")
            }

            Section {
                TuningSlider(
                    title: "Minimum distance", value: $model.focusTuning.jumpMinimumDistance, range: 30...250, step: 10,
                    format: { String(format: "%.0f mm", $0) },
                    help: "The pointer only jumps to where you look if that's at least this far away."
                )
                TuningSlider(
                    title: "Direction tolerance", value: $model.focusTuning.jumpMaximumAngle, range: 10...80, step: 5,
                    format: { String(format: "%.0f°", $0) },
                    help: "How closely the mouse must head toward where you look. Lower jumps only on deliberate reaches."
                )
                TuningSlider(
                    title: "Movement before jumping", value: $model.focusTuning.jumpDecisionDistance, range: 6...80, step: 2,
                    format: { String(format: "%.0f pt", $0) },
                    help: "How far the mouse moves before deciding. Higher ignores nudges."
                )
            } header: {
                Text("Pointer jump")
            }

            Section {
                Button("Restore Defaults") { model.focusTuning = defaults }
                    .disabled(model.focusTuning == defaults)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }
}

/// The camera's field of view, which macOS doesn't report. It shapes how far away the face is
/// estimated and how the network's view of it is set up, so it's fixed per calibration.
private struct CameraSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let typical = GazeModel.defaultFieldOfView
        let calibrated = model.profile?.model.fieldOfView
        let wanted = model.cameraFieldOfView ?? typical

        Section {
            Toggle(isOn: Binding(
                get: { model.cameraFieldOfView != nil },
                set: { model.cameraFieldOfView = $0 ? (calibrated ?? typical) : nil }
            )) {
                Text("Enter the camera's field of view")
                Text("Off, Gaze assumes a typical \(Int(typical))°. The horizontal angle the camera sees, at the resolution Gaze uses (1080p).")
            }
            if model.cameraFieldOfView != nil {
                LabeledContent("Horizontal field of view") {
                    HStack(spacing: 4) {
                        TextField("", value: Binding(get: { wanted }, set: { model.cameraFieldOfView = $0 }), format: .number.precision(.fractionLength(0...1)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("°")
                        Stepper("", value: Binding(get: { wanted }, set: { model.cameraFieldOfView = $0 }), in: GazeModel.fieldOfViewRange, step: 1)
                            .labelsHidden()
                    }
                }
            }
            if let calibrated, abs(calibrated - wanted) > 0.05 {
                Text("“\(model.profile?.name ?? "")” was calibrated with \(calibrated, format: .number.precision(.fractionLength(0...1)))°. Recalibrate to use \(wanted, format: .number.precision(.fractionLength(0...1)))°.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Camera")
        }
    }
}

private struct TuningSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
