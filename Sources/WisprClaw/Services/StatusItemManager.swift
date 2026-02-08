import AppKit
import SwiftUI

final class StatusItemManager: NSObject, NSWindowDelegate {
    enum AppState {
        case idle
        case listening
        case transcribing
        case thinking
    }

    private let statusItem: NSStatusItem
    private let recorder = AudioRecorder()
    private let client = TranscriptionClient()
    private let openClaw = OpenClawClient()
    private var appState: AppState = .idle
    private var hotkeyManager: GlobalHotkeyManager?

    // Dynamic menu items
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var lastResultMenuItem: NSMenuItem!
    private var lastResponseMenuItem: NSMenuItem!
    private var settingsWindow: NSWindow?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: "WisprClaw")
        }

        buildMenu()

        hotkeyManager = GlobalHotkeyManager { [weak self] in
            self?.toggleRecording()
        }
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

        lastResultMenuItem = NSMenuItem(title: "Last transcription: —", action: #selector(copyLastResult), keyEquivalent: "")
        lastResultMenuItem.target = self
        menu.addItem(lastResultMenuItem)

        lastResponseMenuItem = NSMenuItem(title: "OpenClaw response: —", action: #selector(copyLastResponse), keyEquivalent: "")
        lastResponseMenuItem.target = self
        menu.addItem(lastResponseMenuItem)

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
            statusItem.button?.image = NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: "WisprClaw")
        case .listening:
            statusMenuItem.title = "Status: Listening"
            toggleMenuItem.title = "Stop Recording"
            toggleMenuItem.isEnabled = true
            statusItem.button?.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "WisprClaw Recording")
        case .transcribing:
            statusMenuItem.title = "Status: Transcribing"
            toggleMenuItem.isEnabled = false
            statusItem.button?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "WisprClaw Transcribing")
        case .thinking:
            statusMenuItem.title = "Status: Thinking"
            toggleMenuItem.isEnabled = false
            statusItem.button?.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "WisprClaw Thinking")
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
                        self.lastResultMenuItem.title = "Last transcription: \(self.truncateForMenu(text))"
                        self.lastResultMenuItem.toolTip = text
                        self.updateState(.thinking)
                    }

                    do {
                        let response = try await openClaw.send(text: text)
                        await MainActor.run {
                            self.lastResponseMenuItem.title = "OpenClaw response: \(self.truncateForMenu(response))"
                            self.lastResponseMenuItem.toolTip = response
                            ResponsePopupController.shared.show(text: response)
                            self.updateState(.idle)
                        }
                    } catch {
                        await MainActor.run {
                            self.lastResponseMenuItem.title = "OpenClaw response: Error — \(error.localizedDescription)"
                            self.lastResponseMenuItem.toolTip = nil
                            self.updateState(.idle)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.lastResultMenuItem.title = "Last transcription: Error — \(error.localizedDescription)"
                        self.lastResultMenuItem.toolTip = nil
                        self.updateState(.idle)
                    }
                }
            }
        case .transcribing, .thinking:
            break
        }
    }

    private func truncateForMenu(_ text: String, maxLength: Int = 60) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }

    @objc private func copyLastResult() {
        let value = lastResultMenuItem.toolTip ?? lastResultMenuItem.title
            .replacingOccurrences(of: "Last transcription: ", with: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func copyLastResponse() {
        let value = lastResponseMenuItem.toolTip ?? lastResponseMenuItem.title
            .replacingOccurrences(of: "OpenClaw response: ", with: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "WisprClaw Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }

        guard let window = settingsWindow else { return }

        // Temporarily become a regular app so the window can receive focus.
        NSApp.setActivationPolicy(.regular)

        // Give the run loop a tick so the policy change registers, then show.
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Revert to accessory (menu bar-only) once the settings window closes.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
