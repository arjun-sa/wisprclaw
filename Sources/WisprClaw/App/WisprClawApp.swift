import SwiftUI

@main
struct WisprClawApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible windows — everything is driven from the menu bar.
        // Settings are opened manually via StatusItemManager.openSettings().
        Settings {
            EmptyView()
        }
    }
}
