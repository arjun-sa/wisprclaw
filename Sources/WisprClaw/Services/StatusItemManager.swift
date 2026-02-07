import AppKit
import SwiftUI

final class StatusItemManager {
    enum AppState {
        case idle
        case listening
        case transcribing
    }

    private let statusItem: NSStatusItem
    private let recorder = AudioRecorder()
    private let client = TranscriptionClient()
    private var appState: AppState = .idle

    // Dynamic menu items
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var lastResultMenuItem: NSMenuItem!

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WisprClaw")
        }

        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        toggleMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        lastResultMenuItem = NSMenuItem(title: "", action: #selector(copyLastResult), keyEquivalent: "")
        lastResultMenuItem.target = self
        lastResultMenuItem.isHidden = true
        menu.addItem(lastResultMenuItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit WisprClaw", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateState(_ newState: AppState) {
        appState = newState

        switch newState {
        case .idle:
            statusMenuItem.title = "Status: Idle"
            toggleMenuItem.title = "Start Recording"
            toggleMenuItem.isEnabled = true
            statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WisprClaw")
        case .listening:
            statusMenuItem.title = "Status: Listening"
            toggleMenuItem.title = "Stop Recording"
            toggleMenuItem.isEnabled = true
            statusItem.button?.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "WisprClaw Recording")
        case .transcribing:
            statusMenuItem.title = "Status: Transcribing"
            toggleMenuItem.isEnabled = false
            statusItem.button?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "WisprClaw Transcribing")
        }
    }

    @objc private func toggleRecording() {
        switch appState {
        case .idle:
            recorder.requestPermission { [weak self] (granted: Bool) in
                DispatchQueue.main.async {
                    guard granted, let self = self else { return }
                    self.recorder.startRecording()
                    self.updateState(.listening)
                }
            }
        case .listening:
            guard let fileURL = recorder.stopRecording() else {
                updateState(.idle)
                return
            }

            updateState(.transcribing)

            let gatewayURL = UserDefaults.standard.string(forKey: "gatewayURL") ?? "http://localhost:8001"

            Task {
                do {
                    let text = try await client.transcribe(fileURL: fileURL, gatewayURL: gatewayURL)
                    await MainActor.run {
                        self.lastResultMenuItem.title = "Last: \(text)"
                        self.lastResultMenuItem.isHidden = false
                        self.updateState(.idle)
                    }
                } catch {
                    await MainActor.run {
                        self.lastResultMenuItem.title = "Last: Error — \(error.localizedDescription)"
                        self.lastResultMenuItem.isHidden = false
                        self.updateState(.idle)
                    }
                }
            }
        case .transcribing:
            break
        }
    }

    @objc private func copyLastResult() {
        let text = lastResultMenuItem.title
        let value = text.hasPrefix("Last: ") ? String(text.dropFirst(6)) : text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
