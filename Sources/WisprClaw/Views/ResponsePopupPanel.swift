import AppKit

// MARK: - Panel

final class ResponsePopupPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
    }
}

// MARK: - View

final class ResponsePopupView: NSView {
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let closeButton: NSButton
    private let visualEffectView: NSVisualEffectView
    var onDismiss: (() -> Void)?
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    init(text: String, maxWidth: CGFloat, maxHeight: CGFloat) {
        let padding: CGFloat = 12
        let textWidth = maxWidth - padding * 2

        // Create text view with a real frame width so text wraps correctly
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: 0))
        scrollView = NSScrollView()
        closeButton = NSButton()
        visualEffectView = NSVisualEffectView()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // Frosted glass background
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffectView)

        // Close button
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.contentTintColor = .labelColor
        closeButton.target = self
        closeButton.action = #selector(dismissClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        // Text view (selectable, not editable)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text

        // Force layout to measure text height
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let textHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 40
        textView.frame.size.height = textHeight

        // Scroll view
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Re-add close button last so it's on top of the scroll view
        closeButton.removeFromSuperview()
        addSubview(closeButton)

        // Layout — scroll view starts below the close button row
        let buttonSize: CGFloat = 20
        let topInset: CGFloat = 8 + buttonSize + 4  // button top margin + button + gap
        NSLayoutConstraint.activate([
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: buttonSize),
            closeButton.heightAnchor.constraint(equalToConstant: buttonSize),

            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])

        let totalHeight = min(textHeight + topInset + padding, maxHeight)
        frame = NSRect(x: 0, y: 0, width: maxWidth, height: totalHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    @objc private func dismissClicked() {
        onDismiss?()
    }
}

// MARK: - Controller

final class ResponsePopupController {
    static let shared = ResponsePopupController()

    private var panel: ResponsePopupPanel?
    private var dismissTimer: Timer?
    private var isHovered = false
    private var dismissInterval: TimeInterval = 30

    private init() {}

    func show(text: String) {
        dismiss()

        let maxWidth: CGFloat = 360
        let maxHeight: CGFloat = 300

        let popupView = ResponsePopupView(text: text, maxWidth: maxWidth, maxHeight: maxHeight)
        popupView.onDismiss = { [weak self] in self?.dismiss() }
        popupView.onMouseEnter = { [weak self] in self?.pauseDismiss() }
        popupView.onMouseExit = { [weak self] in self?.resumeDismiss() }

        let panelRect = NSRect(origin: .zero, size: popupView.frame.size)
        let newPanel = ResponsePopupPanel(contentRect: panelRect)
        newPanel.contentView = popupView

        // Position top-right of main screen
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let margin: CGFloat = 16
            let x = visibleFrame.maxX - maxWidth - margin
            let y = visibleFrame.maxY - popupView.frame.height - margin
            newPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            newPanel.animator().alphaValue = 1
        }

        panel = newPanel
        isHovered = false
        startDismissTimer()
    }

    private func startDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: dismissInterval, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func pauseDismiss() {
        isHovered = true
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    private func resumeDismiss() {
        isHovered = false
        startDismissTimer()
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let panel else { return }
        let panelRef = panel
        self.panel = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panelRef.animator().alphaValue = 0
        }, completionHandler: {
            panelRef.orderOut(nil)
        })
    }
}
