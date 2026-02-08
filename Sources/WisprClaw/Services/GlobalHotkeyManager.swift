import AppKit
import ApplicationServices

final class GlobalHotkeyManager {
    private let onToggle: () -> Void

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    private var defaultsObservation: NSKeyValueObservation?

    // Double-tap state
    private var lastCmdReleaseTime: TimeInterval = 0
    private var cmdIsDown = false
    private var keyPressedDuringCmd = false
    private var tapCount = 0

    private static let doubleTapInterval: TimeInterval = 0.4

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "doubleTapCmdEnabled")
    }

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle

        // Set default to true if not yet set
        if UserDefaults.standard.object(forKey: "doubleTapCmdEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "doubleTapCmdEnabled")
        }

        // Clean up old hotkey defaults
        UserDefaults.standard.removeObject(forKey: "hotkeyKeyCode")
        UserDefaults.standard.removeObject(forKey: "hotkeyModifiers")

        observeDefaults()

        if isEnabled {
            startMonitoring()
        }
    }

    deinit {
        stopMonitoring()
        defaultsObservation = nil
    }

    // MARK: - Defaults Observation

    private func observeDefaults() {
        defaultsObservation = UserDefaults.standard.observe(
            \.doubleTapCmdEnabled, options: [.new]
        ) { [weak self] _, change in
            guard let self else { return }
            if change.newValue == true {
                self.startMonitoring()
            } else {
                self.stopMonitoring()
            }
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard globalFlagsMonitor == nil else { return }

        requestAccessibilityIfNeeded()

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.handleKeyDown()
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown()
            return event
        }
    }

    func stopMonitoring() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyDownMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyDownMonitor { NSEvent.removeMonitor(m) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyDownMonitor = nil
        localKeyDownMonitor = nil
        resetState()
    }

    // MARK: - Double-Tap Detection

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdOnly = flags == .command

        if cmdOnly && !cmdIsDown {
            // Cmd pressed (no other modifiers)
            cmdIsDown = true
            keyPressedDuringCmd = false
        } else if flags.isEmpty && cmdIsDown {
            // Cmd released cleanly
            cmdIsDown = false

            guard !keyPressedDuringCmd else {
                resetState()
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            if tapCount == 1 && (now - lastCmdReleaseTime) <= Self.doubleTapInterval {
                // Second tap within window — fire!
                resetState()
                onToggle()
            } else {
                // First tap
                tapCount = 1
                lastCmdReleaseTime = now
            }
        } else if !cmdOnly && cmdIsDown {
            // Another modifier added while Cmd held, or Cmd released with other mods
            resetState()
        } else if flags.isEmpty && !cmdIsDown {
            // All keys released but we weren't tracking Cmd — ignore
        } else {
            // Non-Cmd modifier pressed alone
            resetState()
        }
    }

    private func handleKeyDown() {
        if cmdIsDown {
            keyPressedDuringCmd = true
        }
        // Any key press also invalidates a pending first tap
        tapCount = 0
    }

    private func resetState() {
        cmdIsDown = false
        keyPressedDuringCmd = false
        tapCount = 0
        lastCmdReleaseTime = 0
    }

    // MARK: - Accessibility

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - KVO-compatible UserDefaults extension

extension UserDefaults {
    @objc dynamic var doubleTapCmdEnabled: Bool {
        get { bool(forKey: "doubleTapCmdEnabled") }
        set { set(newValue, forKey: "doubleTapCmdEnabled") }
    }
}
