import SwiftUI
import ShizukuCore

@main
struct ShizukuClawApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(appState)
                .frame(minWidth: 480, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
