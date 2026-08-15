import AppKit
import DictateCore

/// Borderless HUD that can be dragged without activating the app.
@MainActor
final class OverlayPanel {
    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyView = OverlayTextView()
    private let scrollView = NSScrollView()
    private var rememberedOrigin: NSPoint?
    private var hasBeenPlaced = false
    private var hideWorkItem: DispatchWorkItem?

    private static let width: CGFloat = 620
    private static let minHeight: CGFloat = 120
    private static let maxHeight: CGFloat = 360
    private static let horizontalPad: CGFloat = 18
    private static let topPad: CGFloat = 14
    private static let bottomPad: CGFloat = 14

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.minHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true

        let blur = DragBlurView(frame: panel.contentView?.bounds ?? .zero)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyView.drawsBackground = false
        bodyView.isEditable = false
        bodyView.isSelectable = false
        bodyView.isRichText = true
        bodyView.textContainerInset = NSSize(width: 0, height: 0)
        bodyView.textContainer?.lineFragmentPadding = 0
        bodyView.textContainer?.widthTracksTextView = true
        bodyView.isVerticallyResizable = true
        bodyView.isHorizontallyResizable = false
        bodyView.autoresizingMask = [.width]
        bodyView.minSize = NSSize(width: 0, height: 0)
        bodyView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        bodyView.font = .systemFont(ofSize: 17, weight: .regular)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = bodyView
        blur.addSubview(statusLabel)
        blur.addSubview(scrollView)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: blur.topAnchor, constant: Self.topPad),
            statusLabel.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: Self.horizontalPad),
            statusLabel.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -Self.horizontalPad),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: Self.horizontalPad),
            scrollView.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -Self.horizontalPad),
            scrollView.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -Self.bottomPad),
        ])
        panel.contentView = blur
        panel.orderOut(nil)
    }

    func show(session: DictateSession, status: String) {
        present(
            status: status,
            spoken: session.displayCommitted,
            draft: session.partial,
            translation: session.displayTranslation
        )
    }

    func showMessage(_ message: String) {
        present(status: "Dictate", spoken: message, draft: "", translation: "")
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if panel.isVisible {
            rememberedOrigin = panel.frame.origin
        }
        panel.orderOut(nil)
        hasBeenPlaced = false
    }

    func hide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func present(status: String, spoken: String, draft: String, translation: String) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        statusLabel.stringValue = status
        let locked = spoken.isEmpty && draft.isEmpty ? "…" : spoken
        bodyView.setContent(spoken: locked, draft: draft, translation: translation)

        let textWidth = Self.width - Self.horizontalPad * 2
        bodyView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        bodyView.setFrameSize(NSSize(width: textWidth, height: 10_000))
        bodyView.layoutManager?.ensureLayout(for: bodyView.textContainer!)
        let used = bodyView.layoutManager?.usedRect(for: bodyView.textContainer!).height ?? 40
        let contentHeight = max(used + 4, 40)
        bodyView.setFrameSize(NSSize(width: textWidth, height: contentHeight))
        let chrome = Self.topPad + 18 + 6 + Self.bottomPad
        let desired = chrome + contentHeight + 8
        let height = min(Self.maxHeight, max(Self.minHeight, desired))

        applyFrame(height: height)
        scrollToEnd()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func applyFrame(height: CGFloat) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        if !hasBeenPlaced {
            let origin: NSPoint
            if let rememberedOrigin {
                origin = clamp(origin: rememberedOrigin, size: NSSize(width: Self.width, height: height), in: visible)
            } else {
                origin = NSPoint(
                    x: visible.midX - Self.width / 2,
                    y: visible.maxY - height - 28
                )
            }
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
            hasBeenPlaced = true
            return
        }

        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.size.width = Self.width
        frame.origin.y = top - height
        frame.origin = clamp(origin: frame.origin, size: frame.size, in: visible)
        panel.setFrame(frame, display: true)
    }

    private func clamp(origin: NSPoint, size: NSSize, in visible: NSRect) -> NSPoint {
        var x = origin.x
        var y = origin.y
        if x < visible.minX { x = visible.minX + 8 }
        if x + size.width > visible.maxX { x = visible.maxX - size.width - 8 }
        if y < visible.minY { y = visible.minY + 8 }
        if y + size.height > visible.maxY { y = visible.maxY - size.height - 8 }
        return NSPoint(x: x, y: y)
    }

    private func scrollToEnd() {
        bodyView.layoutSubtreeIfNeeded()
        let maxY = max(bodyView.bounds.height, scrollView.contentView.bounds.height)
        bodyView.scroll(NSPoint(x: 0, y: maxY))
    }
}

private final class DragBlurView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class OverlayTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    func setContent(spoken: String, draft: String, translation: String) {
        let body = NSMutableAttributedString()
        let spokenFont = NSFont.systemFont(ofSize: 17, weight: .regular)
        let draftFont = NSFont.systemFont(ofSize: 17, weight: .regular)
        let transFont = NSFont.systemFont(ofSize: 14, weight: .regular)
        if !spoken.isEmpty {
            body.append(NSAttributedString(string: spoken, attributes: [
                .font: spokenFont,
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        if !draft.isEmpty {
            let prefix = spoken.isEmpty ? "" : " "
            body.append(NSAttributedString(string: prefix + draft, attributes: [
                .font: draftFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .obliqueness: 0.15,
            ]))
        }
        if !translation.isEmpty {
            body.append(NSAttributedString(string: "\n\n" + translation, attributes: [
                .font: transFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        textStorage?.setAttributedString(body)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
