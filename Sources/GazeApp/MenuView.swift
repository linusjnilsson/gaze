import GazeKit
import SwiftUI

/// The main window: controls on the left, live tracker view on the right.
struct MainView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ControlsView()
                .frame(width: 300)
            Divider()
            DebugView()
        }
    }
}

struct MenuView: View {
    let updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ControlsView()
            Divider()
            HStack {
                Button("Open Gaze Window") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(16)
            HStack(spacing: 14) {
                Button("About & Credits") { openWindow(id: "about") }
                if updater.isAvailable {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                }
                Spacer()
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 300)
    }
}

struct ControlsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var engine = model.engine

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                GazeMark()
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text("Gaze").font(.headline)
                Spacer()
                StatusPill(engine: model.engine)
            }

            if model.engine.isRunning, let issue = model.engine.trackingIssue, issue != .noFace {
                Text(issue.message).font(.callout).foregroundStyle(.orange)
            }

            if let error = model.engine.cameraError {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            ProfileSection()

            Button {
                model.startCalibration()
            } label: {
                Label(model.profile == nil ? "Calibrate" : "Recalibrate", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!model.engine.isRunning || model.calibration.isActive)

            Divider()

            Toggle("Show gaze dot", isOn: $model.showGazeDot)
                .disabled(model.engine.model == nil)
            if model.showGazeDot {
                Toggle("Also show raw estimate", isOn: $model.showRawGaze)
                    .controlSize(.small)
                    .padding(.leading, 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Steadiness")
                Slider(value: $engine.smoothing, in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Fast").font(.caption)
                } maximumValueLabel: {
                    Text("Steady").font(.caption)
                }
            }

            Picker("Tracking", selection: $model.trackingMode) {
                ForEach(AppModel.TrackingMode.allCases) { Text($0.label).tag($0) }
            }
            .controlSize(.small)
            .fixedSize()
            .help("Light tracking uses half the camera frames: about half the processing and battery, with the gaze point a little slower to follow your eyes.")

            Toggle("Save calibration recordings", isOn: $model.recordCalibrations)
                .controlSize(.small)
                .help("Keeps each calibration's face images and measurements on this Mac, for testing tracking methods.")

            Divider()

            FocusSection()

            Divider()

            LearningSection()
        }
        .padding(16)
    }
}

/// The active profile, switching between profiles for these displays, and managing them.
private struct ProfileSection: View {
    @Environment(AppModel.self) private var model
    @State private var isCreating = false
    @State private var renaming: CalibrationProfile?
    @State private var deleting: CalibrationProfile?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                Section("These displays") {
                    ForEach(model.matchingProfiles) { profile in
                        Toggle(profile.name, isOn: Binding(
                            get: { profile.id == model.profile?.id },
                            set: { if $0 { model.selectProfile(profile.id) } }
                        ))
                    }
                    Button("New Profile…") {
                        name = ""
                        isCreating = true
                    }
                    .disabled(!model.engine.isRunning || model.calibration.isActive)
                }
                if let profile = model.profile {
                    Section {
                        Button("Rename “\(profile.name)”…") { startRenaming(profile) }
                        Button("Delete “\(profile.name)”…", role: .destructive) { deleting = profile }
                    }
                }
                if !model.otherProfiles.isEmpty {
                    Section("Other setups") {
                        ForEach(model.otherProfiles) { profile in
                            Menu(profile.name) {
                                Button("Rename…") { startRenaming(profile) }
                                Button("Delete…", role: .destructive) { deleting = profile }
                            }
                        }
                    }
                }
            } label: {
                Label(model.profile?.name ?? "No profile for these displays", systemImage: "person.crop.rectangle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Group {
                if let profile = model.profile, model.calibrationOutdated {
                    Text("Tracking was improved. Recalibrate “\(profile.name)” to use it; its old calibration doesn't carry over.")
                } else if let profile = model.profile {
                    if let report = profile.validation {
                        Text(String(format: "Error %.0f mm still · %.0f mm moving", report.stillErrorMillimeters, report.movingErrorMillimeters))
                    }
                    Text("Tracking with \(profile.model.gazeSource.label.lowercased())")
                        .font(.caption)
                    HStack(spacing: 4) {
                        Text("Calibrated")
                        Text(profile.createdAt, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                } else {
                    Text("\(model.displays.count) display\(model.displays.count == 1 ? "" : "s") connected. Calibrate to create a profile.")
                }
                if let error = model.saveError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .alert("New Profile", isPresented: $isCreating) {
            TextField("Name", text: $name)
            Button("Calibrate") { model.startCalibration(newProfileName: name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A separate calibration for these displays, for example “Home desk” or “Café”. You'll calibrate it next.")
        }
        .alert("Rename Profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Rename") {
                if let renaming { model.renameProfile(renaming.id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let deleting { model.deleteProfile(deleting.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its calibration and everything learned from your clicks and typing will be removed.")
        }
    }

    private func startRenaming(_ profile: CalibrationProfile) {
        name = profile.name
        renaming = profile
    }
}

/// Switching focus to where the user looks, and the pointer jump.
private struct FocusSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 6) {
            Toggle("Switch focus by looking", isOn: $model.switchFocus)
                .disabled(model.engine.model == nil)
            if model.switchFocus {
                Picker("Trigger", selection: $model.focusTrigger) {
                    ForEach(TriggerKey.groups, id: \.0) { title, triggers in
                        Section(title) {
                            ForEach(triggers) { Text($0.label).tag($0) }
                        }
                    }
                }
                .controlSize(.small)
                .padding(.leading, 20)
                .fixedSize()
                Group {
                    Text("Look at a window and \(model.focusTrigger.action). Hold it to see which window it picks, and tap \(model.focusTrigger.overviewKey) to see all windows and pick one by looking; press any other key to cancel.")
                    if let note = model.focusTrigger.note {
                        Text(note)
                    }
                    if let problem = model.focus.triggerProblem {
                        Text(problem).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .fixedSize(horizontal: false, vertical: true)
                Picker("Pane trigger", selection: $model.paneTrigger) {
                    Text("Off").tag(TriggerKey?.none)
                    ForEach(TriggerKey.paneOptions(besides: model.focusTrigger), id: \.0) { title, triggers in
                        Section(title) {
                            ForEach(triggers) { Text($0.label).tag(TriggerKey?.some($0)) }
                        }
                    }
                }
                .controlSize(.small)
                .padding(.leading, 20)
                .fixedSize()
                if let pane = model.paneTrigger {
                    Text("Inside the focused window, look at a pane (a terminal split, an editor, a sidebar) and \(pane.action) to focus it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.displays.count > 1 {
                    Toggle("Switch displays by looking", isOn: $model.focusTuning.switchesDisplays)
                        .controlSize(.small)
                        .padding(.leading, 20)
                        .help("Look at another display for a moment and focus moves there, to the window you last used on it. Not while typing or using the mouse.")
                }
                if let result = model.focus.lastResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }

            Toggle("Move pointer to where you look", isOn: $model.pointerJump)
                .disabled(model.engine.model == nil)
                .help("When you start moving the mouse toward where you're looking, the pointer jumps there and you finish by hand.")

            if !model.hasAccessibilityAccess {
                HStack {
                    Text("Switching focus needs Accessibility access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Grant…") { model.requestAccessibilityAccess() }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Status and settings for learning from clicks and typing.
private struct LearningSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let learner = model.learner

        VStack(alignment: .leading, spacing: 6) {
            Toggle("Learn from clicks and typing", isOn: $model.learnFromInteractions)
                .disabled(model.engine.model == nil)

            Group {
                switch learner.status {
                case .notCalibrated:
                    EmptyView()
                case .collecting:
                    Text("Collecting everyday clicks (\(learner.everydayEventCount) so far)")
                case .learning:
                    HStack(spacing: 4) {
                        Text("Learned from \(learner.everydayEventCount) interactions")
                        if let adjusted = learner.lastAdjusted {
                            Text("· adjusted")
                            Text(adjusted, format: .relative(presentation: .named))
                        }
                    }
                case .drifting:
                    Text("Accuracy dropped. Something changed (lighting, glasses, seating?), so learning is adapting faster. Recalibrate for the best result.")
                        .foregroundStyle(.orange)
                }
                if let live = learner.liveErrorMillimeters {
                    Text(String(format: "Live accuracy ≈ %.0f mm (last %d clicks)", live, learner.recentErrors.count))
                } else if learner.status != .notCalibrated {
                    Text("Click around normally to measure live accuracy.")
                }
                if let improvement = learner.lastImprovement {
                    Text(String(format: "Last adjustment: %.0f → %.0f mm on unseen clicks", improvement.before, improvement.after))
                    if improvement.personalized {
                        Text("Network personalization relearned from your clicks")
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !model.hasAccessibilityAccess {
                HStack {
                    Text("Learning from typing needs Accessibility access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Grant…") { model.requestAccessibilityAccess() }
                        .controlSize(.small)
                }
            }

            if learner.everydayEventCount > 0 {
                Button("Reset learning", role: .destructive) { model.resetLearning() }
                    .controlSize(.small)
            }
        }
    }
}

private struct StatusPill: View {
    let engine: GazeEngine

    var body: some View {
        let (text, color): (String, Color) =
            if !engine.isRunning { ("Camera off", .secondary) }
            else if !engine.hasFace { (engine.trackingIssue == .noFace ? "No face" : "Face out of view", .orange) }
            else if engine.trackingIssue != nil { (String(format: "Partial · %.0f fps", engine.fps), .yellow) }
            else { (String(format: "Tracking · %.0f fps", engine.fps), .gazeMint) }

        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}
