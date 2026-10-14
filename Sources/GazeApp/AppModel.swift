import AppKit
import GazeKit
import IOKit.ps
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let engine: GazeEngine
    let calibration = CalibrationController()
    let learner: InteractionLearner
    let focus: FocusController

    private(set) var displays: [DisplayInfo] = []
    /// Every saved profile, for any displays.
    private(set) var profiles: [CalibrationProfile] = []
    /// The active profile: one made for the connected displays.
    private(set) var profile: CalibrationProfile?
    private(set) var saveError: String?
    private(set) var hasAccessibilityAccess = InteractionMonitor.hasAccessibilityAccess

    var showGazeDot = false {
        didSet { updateGazeDot() }
    }

    /// Also draws the unstabilized per-frame estimate, for judging tracking noise.
    var showRawGaze = false {
        didSet { updateGazeDot() }
    }

    var learnFromInteractions: Bool {
        get { learner.isEnabled }
        set {
            learner.isEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Self.learnKey)
        }
    }

    /// Saves each calibration's frames, for evaluating tracking methods offline.
    var recordCalibrations: Bool = UserDefaults.standard.object(forKey: AppModel.recordKey) as? Bool ?? false {
        didSet { UserDefaults.standard.set(recordCalibrations, forKey: Self.recordKey) }
    }

    @ObservationIgnored private let gazeDot = GazeDotOverlay()
    @ObservationIgnored private let interactions = InteractionMonitor()
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var accessibilityTimer: Timer?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private var idleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Why the camera is paused right now: the screen is locked, asleep, or another user is active.
    @ObservationIgnored private var pauseReasons: Set<String> = []
    /// Learned samples not yet written to disk; written shortly after, so a burst of clicks is one write.
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    private static let learnKey = "learnFromInteractions"
    private static let recordKey = "recordCalibrations"
    private static let focusKey = "switchFocus"
    private static let triggerKey = "focusTriggerKey"
    private static let pointerJumpKey = "pointerJump"
    private static let paneTriggerKey = "paneTriggerKey"
    private static let tuningKey = "focusTuning"
    private static let fieldOfViewKey = "cameraFieldOfView"
    private static let trackingModeKey = "trackingMode"

    /// How much the tracking may cost: full speed, half the frames, or half while on battery.
    enum TrackingMode: String, CaseIterable, Identifiable {
        case precise, light, lightOnBattery
        var id: Self { self }
        var label: String {
            switch self {
            case .precise: "Precise (30 fps)"
            case .light: "Light (15 fps)"
            case .lightOnBattery: "Light on battery"
            }
        }
    }

    var trackingMode: TrackingMode = UserDefaults.standard.string(forKey: AppModel.trackingModeKey).flatMap(TrackingMode.init) ?? .precise {
        didSet {
            UserDefaults.standard.set(trackingMode.rawValue, forKey: Self.trackingModeKey)
            applyTrackingMode()
        }
    }

    @ObservationIgnored private var powerTimer: Timer?

    private func applyTrackingMode() {
        switch trackingMode {
        case .precise: engine.lightTracking = false
        case .light: engine.lightTracking = true
        case .lightOnBattery: engine.lightTracking = PowerSource.isOnBattery
        }
        // Plugging in or unplugging is noticed within half a minute.
        powerTimer?.invalidate()
        powerTimer = nil
        if trackingMode == .lightOnBattery {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.lightTracking = PowerSource.isOnBattery }
            }
            RunLoop.main.add(timer, forMode: .common)
            powerTimer = timer
        }
    }

    /// The camera's horizontal field of view in degrees, if the user entered it; `nil` uses a
    /// typical one. Takes effect at the next calibration.
    var cameraFieldOfView: Double? = UserDefaults.standard.object(forKey: AppModel.fieldOfViewKey) as? Double {
        didSet {
            if let cameraFieldOfView, !GazeModel.fieldOfViewRange.contains(cameraFieldOfView) {
                self.cameraFieldOfView = min(max(cameraFieldOfView, GazeModel.fieldOfViewRange.lowerBound), GazeModel.fieldOfViewRange.upperBound)
                return
            }
            UserDefaults.standard.set(cameraFieldOfView, forKey: Self.fieldOfViewKey)
            engine.calibrationFieldOfView = cameraFieldOfView ?? GazeModel.defaultFieldOfView
        }
    }

    /// The advanced focus settings.
    var focusTuning = FocusTuning() {
        didSet {
            guard focusTuning != oldValue else { return }
            focus.tuning = focusTuning
            if let data = try? JSONEncoder().encode(focusTuning) {
                UserDefaults.standard.set(data, forKey: Self.tuningKey)
            }
        }
    }

    var switchFocus: Bool {
        get { focus.isEnabled }
        set {
            focus.isEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Self.focusKey)
        }
    }

    var focusTrigger: TriggerKey {
        get { focus.triggerKey }
        set {
            focus.triggerKey = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.triggerKey)
            // The two can't share a modifier: its taps would count for both.
            if let pane = paneTrigger, pane.modifierFlag == newValue.modifierFlag { paneTrigger = nil }
        }
    }

    /// The key that focuses panes inside the focused window; `nil` is off.
    var paneTrigger: TriggerKey? {
        get { focus.paneTrigger }
        set {
            focus.paneTrigger = newValue
            UserDefaults.standard.set(newValue?.rawValue ?? "off", forKey: Self.paneTriggerKey)
        }
    }

    var pointerJump: Bool {
        get { focus.pointerJumpEnabled }
        set {
            focus.pointerJumpEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Self.pointerJumpKey)
        }
    }

    init() {
        let engine = GazeEngine()
        self.engine = engine
        learner = InteractionLearner(engine: engine)
        let defaults = UserDefaults.standard
        focus = FocusController(engine: engine)
        focus.isEnabled = defaults.object(forKey: Self.focusKey) as? Bool ?? true
        focus.triggerKey = defaults.string(forKey: Self.triggerKey).flatMap(TriggerKey.init) ?? .doubleLeftCommand
        focus.pointerJumpEnabled = defaults.object(forKey: Self.pointerJumpKey) as? Bool ?? true
        if let data = defaults.data(forKey: Self.tuningKey), let tuning = try? JSONDecoder().decode(FocusTuning.self, from: data) {
            focusTuning = tuning
            focus.tuning = tuning
        }
        let pane = defaults.string(forKey: Self.paneTriggerKey).map(TriggerKey.init) ?? .doubleOption
        focus.paneTrigger = pane?.modifierFlag == focus.triggerKey.modifierFlag ? nil : pane
        learner.isEnabled = UserDefaults.standard.object(forKey: Self.learnKey) as? Bool ?? true
        engine.calibrationFieldOfView = cameraFieldOfView ?? GazeModel.defaultFieldOfView
        learner.onAdapt = { [weak self] model, samples, improvement in
            self?.saveLearned(model: model, samples: samples, baseline: improvement.after)
        }
        learner.onRecord = { [weak self] _ in
            self?.scheduleLearningSave()
        }

        profiles = CalibrationStore.loadAll()
        refreshDisplays()
        applyTrackingMode()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveLearningNow()
                self?.focus.shutdown()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        }

        interactions.onClick = { [weak self] point, uptime in
            guard let self, !calibration.isActive else { return }
            learner.record(.click, at: point, uptime: uptime)
        }
        interactions.onType = { [weak self] point, uptime in
            guard let self, !calibration.isActive else { return }
            learner.record(.typing, at: point, uptime: uptime)
        }
        interactions.start()
        focus.gazeErrorMillimeters = { [weak self] in
            // Live error needs a few clicks after each launch; until then, the last measured one.
            self?.learner.liveErrorMillimeters ?? self?.profile?.learningBaseline ?? self?.profile?.validation?.stillErrorMillimeters ?? 25
        }
        focus.isSuspended = { [weak self] in self?.calibration.isActive ?? true }
        focus.start()
        focus.applyTrigger()
        if !hasAccessibilityAccess { watchForAccessibilityAccess() }

        watchForIdleScreen()
        Task { await engine.start() }
    }

    /// Pauses the camera while the screen is locked or asleep, or another user's session is active.
    private func watchForIdleScreen() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, String, Bool)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, "asleep", true),
            (workspace, NSWorkspace.screensDidWakeNotification, "asleep", false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, "switched", true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, "switched", false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), "locked", true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), "locked", false),
        ]
        for (center, name, reason, starts) in events {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(starts, because: reason) }
            }
            idleObservers.append((center, observer))
        }
    }

    private func setPaused(_ paused: Bool, because reason: String) {
        // The Mac may not wake up again (battery, shutdown): write what was learned.
        if paused { saveLearningNow() }
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        if pauseReasons.isEmpty { engine.resume() } else { engine.pause() }
    }

    var menuBarIcon: Image {
        if engine.cameraError != nil { return Image(systemName: "exclamationmark.triangle") }
        return Image(nsImage: GazeMenuBarIcon.image(paused: !engine.hasFace))
    }

    var signature: String { DisplayInfo.signature(of: displays) }

    /// Profiles made for the connected displays, most recently used first.
    var matchingProfiles: [CalibrationProfile] {
        profiles.filter { $0.signature == signature }.sorted { ($0.lastUsed ?? $0.createdAt) > ($1.lastUsed ?? $1.createdAt) }
    }

    /// Profiles for other display setups.
    var otherProfiles: [CalibrationProfile] {
        profiles.filter { $0.signature != signature }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The active profile was calibrated with an older version of the tracking and can't be used
    /// until it's recalibrated.
    var calibrationOutdated: Bool {
        profile.map { !$0.model.isCurrentGeometry } ?? false
    }

    /// Picks the most recently used profile for the connected displays, so moving between desks
    /// switches profiles automatically.
    func refreshDisplays() {
        displays = DisplayInfo.current()
        engine.displays = displays
        guard profile?.signature != signature else { return }
        activate(matchingProfiles.first)
    }

    /// Switches to another profile for the connected displays.
    func selectProfile(_ id: UUID) {
        guard id != profile?.id, let chosen = matchingProfiles.first(where: { $0.id == id }) else { return }
        activate(chosen)
    }

    func renameProfile(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var renamed = profiles.first(where: { $0.id == id }) else { return }
        if id == profile?.id { renamed = profile! }
        renamed.name = name
        save(renamed)
    }

    func deleteProfile(_ id: UUID) {
        if id == profile?.id {
            pendingSave?.cancel()
            pendingSave = nil
        }
        do {
            try CalibrationStore.delete(id)
        } catch {
            saveError = "Could not delete profile: \(error.localizedDescription)"
            return
        }
        profiles.removeAll { $0.id == id }
        if id == profile?.id {
            profile = nil
            activate(matchingProfiles.first)
        }
    }

    /// Makes `next` the active profile, saving what the current one learned first.
    private func activate(_ next: CalibrationProfile?) {
        saveLearningNow()
        profile = next
        if var next {
            next.lastUsed = .now
            save(next)
        }
        // A profile from an older tracking version stays selected (so it can be recalibrated in
        // place, keeping its name) but isn't used.
        let usable = profile.flatMap { $0.model.isCurrentGeometry ? $0 : nil }
        engine.model = usable?.model
        learner.reset(
            base: usable.map { $0.calibratedModel ?? $0.model },
            samples: usable?.interactions ?? [],
            lastAdjusted: usable?.lastAdjusted,
            baselineError: usable?.learningBaseline
        )
        updateGazeDot()
    }

    /// Calibrates the active profile, or with `newProfileName`, creates a new profile for the
    /// connected displays once calibration succeeds.
    func startCalibration(newProfileName: String? = nil) {
        gazeDot.hide()
        let displays = displays
        let signature = signature
        let current = newProfileName == nil ? profile : nil
        let name = newProfileName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let recording = recordCalibrations ? CalibrationRecorder.newSessionURL() : nil
        calibration.start(engine: engine, displays: displays, recordTo: recording) { [weak self] model, report, samples in
            guard let self else { return }
            var calibrated: CalibrationProfile
            if var current {
                current.recalibrate(model: model, validation: report, samples: samples, displays: displays, signature: signature)
                calibrated = current
            } else {
                calibrated = CalibrationProfile(name: name, signature: signature, displays: displays, model: model, validation: report)
                calibrated.interactions = samples
            }
            // Learning restarts from this calibration: earlier samples were measured against the
            // old calibration's geometry.
            pendingSave?.cancel()
            pendingSave = nil
            profile = nil
            activate(calibrated)
        } onClose: { [weak self] in
            self?.updateGazeDot()
        }
    }

    /// Discards what was learned from interactions and goes back to the explicit calibration.
    func resetLearning() {
        guard var profile else { return }
        pendingSave?.cancel()
        pendingSave = nil
        let calibrated = profile.calibratedModel ?? profile.model
        let calibrationSamples = (profile.interactions ?? []).filter { $0.source == .calibration }
        profile.model = calibrated
        profile.interactions = calibrationSamples
        profile.lastAdjusted = nil
        profile.learningBaseline = nil
        save(profile)
        engine.model = calibrated
        learner.reset(base: calibrated, samples: calibrationSamples)
    }

    func requestAccessibilityAccess() {
        InteractionMonitor.requestAccessibilityAccess()
        watchForAccessibilityAccess()
    }

    /// Takes a refit model in use at once; it reaches the disk with the next learning save.
    private func saveLearned(model: GazeModel, samples: [InteractionSample], baseline: Double) {
        guard var profile else { return }
        profile.model = model
        profile.interactions = samples
        profile.lastAdjusted = .now
        profile.learningBaseline = baseline
        remember(profile)
        scheduleLearningSave()
    }

    /// How long learned samples may wait in memory before they're written. A profile is several
    /// megabytes, and writing it after every click came to gigabytes a day; on a crash, only this
    /// much learning is lost. Sleep, locking, switching profiles and quitting write sooner.
    static let learningSaveDelay: Duration = .seconds(600)

    private func scheduleLearningSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.learningSaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveLearningNow()
        }
    }

    /// Writes learned samples that haven't been saved yet.
    private func saveLearningNow() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        guard var profile, profile.model.isCurrentGeometry else { return }
        profile.interactions = learner.samples
        save(profile)
    }

    private func save(_ profile: CalibrationProfile) {
        do {
            try CalibrationStore.save(profile)
            saveError = nil
        } catch {
            saveError = "Could not save profile: \(error.localizedDescription)"
        }
        remember(profile)
    }

    /// Updates the profile in memory only.
    private func remember(_ profile: CalibrationProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if self.profile?.id == profile.id {
            self.profile = profile
        }
    }

    /// Accessibility access is granted in System Settings, outside the app, so poll for it.
    /// Global key monitoring only starts working once monitors are installed with access.
    private func watchForAccessibilityAccess() {
        guard accessibilityTimer == nil else { return }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, InteractionMonitor.hasAccessibilityAccess else { return }
                self.hasAccessibilityAccess = true
                self.accessibilityTimer?.invalidate()
                self.accessibilityTimer = nil
                self.interactions.start()
                self.focus.start()
                self.focus.applyTrigger()
            }
        }
    }

    private func updateGazeDot() {
        if showGazeDot, !calibration.isActive {
            gazeDot.show(engine: engine, showRaw: showRawGaze)
        } else {
            gazeDot.hide()
        }
    }
}

/// Whether the Mac is running on its battery.
enum PowerSource {
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
