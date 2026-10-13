import Sparkle
import SwiftUI

/// Checks for new versions through Sparkle: daily on its own, and from the menu.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        // Builds without a feed (or its signing key) don't update.
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] != nil, info["SUPublicEDKey"] != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        // Gaze lives in the menu bar; bring the update window to the front.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// Gaze is a menu bar app, so Sparkle asks for gentle reminders rather than windows popping up
    /// over whatever is in front. Sparkle still shows them; this only tells it that's intended.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
