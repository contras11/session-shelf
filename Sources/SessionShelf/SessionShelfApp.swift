import SwiftUI

@main
struct SessionShelfApp: App {
    @StateObject private var sidebarPreferences = SidebarPreferences()

    var body: some Scene {
        WindowGroup("Session Shelf") {
            ContentView(sidebarPreferences: sidebarPreferences)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("再読み込み") {
                    NotificationCenter.default.post(name: .sessionShelfReload, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SidebarSettingsView(preferences: sidebarPreferences)
        }
    }
}

extension Notification.Name {
    static let sessionShelfReload = Notification.Name("SessionShelfReload")
}
