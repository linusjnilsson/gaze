import SwiftUI

@main
struct GazeApp: App {
    @State private var model = AppModel()
    @State private var updater = Updater()

    var body: some Scene {
        // Declared first so it opens at launch.
        Window("Gaze", id: "main") {
            MainView()
                .environment(model)
                // In the Dock only while the window is open; otherwise Gaze lives in the menu bar.
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 1040, height: 540)

        Settings {
            FocusSettingsView()
                .environment(model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear {
                    // Back to the menu bar only, unless the main window is still open.
                    if !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue == "main" }) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }

        Window("About Gaze", id: "about") {
            CreditsView()
                .onAppear { NSApp.activate() }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuView(updater: updater)
                .environment(model)
        } label: {
            model.menuBarIcon
        }
        .menuBarExtraStyle(.window)
    }
}

