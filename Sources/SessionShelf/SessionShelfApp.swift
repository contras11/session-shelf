import SwiftUI

@main
struct SessionShelfApp: App {
    var body: some Scene {
        WindowGroup("Session Shelf") {
            ContentView()
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
    }
}

extension Notification.Name {
    static let sessionShelfReload = Notification.Name("SessionShelfReload")
}
