import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemManager: StatusItemManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemManager = StatusItemManager()
    }
}
