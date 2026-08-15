import AppKit
import DictateCore

/// Fixed, click-through notch HUD. The host window never changes size while
/// recognition is active, so partial updates cannot make the UI jump.
@MainActor
final class OverlayPanel {
    private let panel: NSPanel
    private let hudView: NotchHUDView
    private var hideWorkItem: DispatchWorkItem?

    private static let size = NSSize(width: 560, height: 118)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        hudView = NotchHUDView(frame: NSRect(origin: .zero, size: Self.size))

        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = hudView
        panel.orderOut(nil)
    }

    func show(session: DictateSession, status: String, localeIdentifier: String) {
        present(
            status: status,
            spoken: session.displayCommitted,
            draft: session.partial,
            translation: session.displayTranslation,
            localeIdentifier: localeIdentifier,
            isListening: true
        )
    }

    func showMessage(_ message: String) {
        present(
            status: "Dictate",
            spoken: message,
            draft: "",
            translation: "",
            localeIdentifier: "",
            isListening: false
        )
    }

    func showPreview() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let screen = preferredScreen()
        hudView.hasPhysicalNotch = screen.safeAreaInsets.top > 0
        hudView.present(
            status: "正在听…  灰色为草稿，定稿后翻译",
            spoken: "Dictate 会把已经定稿的文字稳定保留下来，",
            draft: "while the latest words stay live on screen",
            translation: "Final translation appears here without blocking live transcription.",
            localeIdentifier: "zh-CN",
            isListening: true,
            isPreview: true
        )
        applyFrame(on: screen)
        panel.orderFrontRegardless()
        hudView.startAnimating()
    }

    func updateAudioLevel(_ level: Float) {
        hudView.updateAudioLevel(CGFloat(level))
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        hudView.stopAnimating()
        panel.orderOut(nil)
    }

    func hide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func present(
        status: String,
        spoken: String,
        draft: String,
        translation: String,
        localeIdentifier: String,
        isListening: Bool
    ) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        let screen = preferredScreen()
        hudView.hasPhysicalNotch = screen.safeAreaInsets.top > 0
        hudView.present(
            status: status,
            spoken: spoken,
            draft: draft,
            translation: translation,
            localeIdentifier: localeIdentifier,
            isListening: isListening,
            isPreview: false
        )
        applyFrame(on: screen)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        hudView.startAnimating()
    }

    private func applyFrame(on screen: NSScreen) {
        let top: CGFloat
        if screen.safeAreaInsets.top > 0 {
            top = screen.frame.maxY
        } else {
            top = screen.visibleFrame.maxY - 10
        }
        let origin = NSPoint(
            x: screen.frame.midX - Self.size.width / 2,
            y: top - Self.size.height
        )
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }

    private func preferredScreen() -> NSScreen {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

@MainActor
private final class NotchHUDView: NSView {
    private let statusLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let translationLabel = NSTextField(labelWithString: "")
    private var animationTimer: Timer?
    private var animationPhase: CGFloat = 0
    private var targetLevel: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var lastLevelUpdate = ContinuousClock.now
    private var isListening = false
    private var isPreview = false
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var hasPhysicalNotch = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setupLabels()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    func present(
        status: String,
        spoken: String,
        draft: String,
        translation: String,
        localeIdentifier: String,
        isListening: Bool,
        isPreview: Bool = false
    ) {
        self.isListening = isListening
        self.isPreview = isPreview
        statusLabel.stringValue = isListening ? "●  \(status)" : status
        statusLabel.textColor = isListening
            ? NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.63, alpha: 1)
            : .secondaryLabelColor
        languageLabel.stringValue = languageTitle(for: localeIdentifier)
        languageLabel.isHidden = localeIdentifier.isEmpty
        bodyLabel.attributedStringValue = bodyText(spoken: spoken, draft: draft)
        translationLabel.stringValue = translation
        translationLabel.isHidden = translation.isEmpty
        needsDisplay = true
    }

    func updateAudioLevel(_ level: CGFloat) {
        targetLevel = min(1, max(0, level))
        lastLevelUpdate = .now
    }

    func startAnimating() {
        guard animationTimer == nil else { return }
        let interval = reduceMotion ? 1.0 / 12.0 : 1.0 / 30.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        targetLevel = 0
        displayedLevel = 0
        animationPhase = 0
        isPreview = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let shellRect = bounds.insetBy(dx: 7, dy: 5)
        let shellPath = CGPath(
            roundedRect: shellRect,
            cornerWidth: 24,
            cornerHeight: 24,
            transform: nil
        )

        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: 16 + displayedLevel * 18,
            color: NSColor(calibratedRed: 0.27, green: 0.72, blue: 1, alpha: 0.28 + displayedLevel * 0.34).cgColor
        )
        context.addPath(shellPath)
        context.setFillColor(NSColor(calibratedWhite: 0.025, alpha: 0.98).cgColor)
        context.fillPath()
        context.restoreGState()

        if hasPhysicalNotch {
            let bridge = CGRect(x: bounds.midX - 96, y: 0, width: 192, height: 25)
            context.setFillColor(NSColor(calibratedWhite: 0.025, alpha: 1).cgColor)
            context.fill(bridge)
        }

        drawGlow(path: shellPath, in: context)
        drawParticles(in: shellRect, context: context)
    }

    private func setupLabels() {
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        languageLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        languageLabel.textColor = NSColor(calibratedRed: 0.48, green: 0.83, blue: 1, alpha: 1)
        languageLabel.alignment = .right
        languageLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.font = .systemFont(ofSize: 16.5, weight: .medium)
        bodyLabel.textColor = .white
        bodyLabel.maximumNumberOfLines = 2
        bodyLabel.lineBreakMode = .byTruncatingHead
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        translationLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        translationLabel.textColor = NSColor(calibratedWhite: 0.67, alpha: 1)
        translationLabel.lineBreakMode = .byTruncatingTail
        translationLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(statusLabel)
        addSubview(languageLabel)
        addSubview(bodyLabel)
        addSubview(translationLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            languageLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            languageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            languageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),

            bodyLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),

            translationLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 4),
            translationLabel.leadingAnchor.constraint(equalTo: bodyLabel.leadingAnchor),
            translationLabel.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor),
            translationLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -15),
        ])
    }

    private func tick() {
        if isPreview {
            targetLevel = 0.52 + sin(animationPhase * 1.7) * 0.24
        } else if lastLevelUpdate.duration(to: .now) > .milliseconds(140) {
            targetLevel = 0
        }
        let response: CGFloat = targetLevel > displayedLevel ? 0.48 : 0.14
        displayedLevel += (targetLevel - displayedLevel) * response
        if reduceMotion {
            displayedLevel = min(displayedLevel, 0.45)
        } else {
            animationPhase += 0.035 + displayedLevel * 0.075
        }
        needsDisplay = true
    }

    private func bodyText(spoken: String, draft: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let stable = spoken.isEmpty && draft.isEmpty ? "开口说话…" : spoken
        if !stable.isEmpty {
            result.append(NSAttributedString(string: stable, attributes: [
                .font: NSFont.systemFont(ofSize: 16.5, weight: .medium),
                .foregroundColor: spoken.isEmpty && draft.isEmpty
                    ? NSColor(calibratedWhite: 0.52, alpha: 1)
                    : NSColor.white,
            ]))
        }
        if !draft.isEmpty {
            result.append(NSAttributedString(string: (spoken.isEmpty ? "" : " ") + draft, attributes: [
                .font: NSFont.systemFont(ofSize: 16.5, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.58, alpha: 1),
                .obliqueness: 0.12,
            ]))
        }
        return result
    }

    private func languageTitle(for localeIdentifier: String) -> String {
        localeIdentifier.lowercased().hasPrefix("en") ? "ENGLISH · FN" : "中文 · 右⌥"
    }

    private func drawGlow(path: CGPath, in context: CGContext) {
        let idleBoost: CGFloat = isListening ? 0.22 : 0.08
        let strength = idleBoost + displayedLevel * 0.78
        let gradientColors = [
            NSColor(calibratedRed: 1, green: 0.19, blue: 0.49, alpha: strength).cgColor,
            NSColor(calibratedRed: 0.68, green: 0.32, blue: 1, alpha: strength).cgColor,
            NSColor(calibratedRed: 0.16, green: 0.84, blue: 1, alpha: strength).cgColor,
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: gradientColors,
            locations: [0, 0.53, 1]
        ) else { return }

        context.saveGState()
        context.addPath(path)
        context.setLineWidth(7 + displayedLevel * 5)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.minX, y: bounds.midY),
            end: CGPoint(x: bounds.maxX, y: bounds.midY),
            options: []
        )
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.setLineWidth(1.2 + displayedLevel * 1.8)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.minX, y: bounds.midY),
            end: CGPoint(x: bounds.maxX, y: bounds.midY),
            options: []
        )
        context.restoreGState()
    }

    private func drawParticles(in rect: CGRect, context: CGContext) {
        guard isListening, !reduceMotion, displayedLevel > 0.025 else { return }
        let colors = [
            NSColor(calibratedRed: 1, green: 0.32, blue: 0.58, alpha: 1),
            NSColor(calibratedRed: 0.61, green: 0.42, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.25, green: 0.85, blue: 1, alpha: 1),
        ]
        for index in 0..<18 {
            let seed = CGFloat(index) * 1.731
            let progress = (CGFloat(index) + 0.5) / 18
            let drift = sin(animationPhase * (0.7 + progress) + seed)
            let lift = abs(cos(animationPhase * 1.25 + seed))
            let x = rect.minX + 20 + progress * (rect.width - 40) + drift * 7
            let y = rect.maxY - 12 - lift * (5 + displayedLevel * 19)
            let radius = 1.1 + displayedLevel * (1.2 + CGFloat(index % 3) * 0.55)
            context.setFillColor(colors[index % colors.count].withAlphaComponent(0.16 + displayedLevel * 0.62).cgColor)
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
    }
}
