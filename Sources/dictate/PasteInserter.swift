import AppKit
import ApplicationServices
import CoreGraphics

enum InsertResult: Equatable {
    case pasteAttempted
    case copied
    case copiedTargetChanged
    case copiedOnly
    case copyFailed
    case blockedSecureField
    case empty
}

@MainActor
final class TargetSnapshot {
    enum Validation {
        case valid
        case changed
        case unavailable
        case secure
    }

    let processIdentifier: pid_t
    let bundleIdentifier: String?
    private let focusedElement: AXUIElement
    private let secure: Bool

    private init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        focusedElement: AXUIElement,
        secure: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.focusedElement = focusedElement
        self.secure = secure
    }

    static func capture() -> TargetSnapshot? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let focused = focusedElement()
        else {
            return nil
        }

        var elementPID: pid_t = 0
        guard AXUIElementGetPid(focused, &elementPID) == .success,
              elementPID == app.processIdentifier
        else {
            return nil
        }

        return TargetSnapshot(
            processIdentifier: elementPID,
            bundleIdentifier: app.bundleIdentifier,
            focusedElement: focused,
            secure: isSecureTextElement(focused)
        )
    }

    func validate() -> Validation {
        if secure { return .secure }
        guard AXIsProcessTrusted() else { return .unavailable }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return .changed
        }
        guard let current = Self.focusedElement() else { return .unavailable }

        var currentPID: pid_t = 0
        guard AXUIElementGetPid(current, &currentPID) == .success else { return .unavailable }
        guard currentPID == processIdentifier else { return .changed }
        if Self.isSecureTextElement(current) { return .secure }
        return CFEqual(focusedElement, current) ? .valid : .changed
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success,
            let subrole = value as? String
        else {
            return false
        }
        return subrole == kAXSecureTextFieldSubrole as String
    }
}

@MainActor
enum PasteInserter {
    static func insert(_ text: String, into target: TargetSnapshot?) -> InsertResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        if target?.validate() == .secure {
            return .blockedSecureField
        }

        let pasteboard = NSPasteboard.general
        let previous = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)

        guard AXIsProcessTrusted(), let target else {
            return .copiedOnly
        }

        switch target.validate() {
        case .valid:
            let ownedChangeCount = pasteboard.changeCount
            guard postCommandV() else { return .copiedOnly }
            restore(
                previous,
                to: pasteboard,
                ifChangeCountIs: ownedChangeCount,
                after: 0.25
            )
            return .pasteAttempted
        case .changed:
            return .copiedTargetChanged
        case .unavailable:
            return .copiedOnly
        case .secure:
            // The secure check above happens before the clipboard write. This
            // branch only covers a target that became secure during commit.
            pasteboard.clearContents()
            previous.restore(to: pasteboard)
            return .blockedSecureField
        }
    }

    static func copy(_ text: String, respecting target: TargetSnapshot?) -> InsertResult {
        if target?.validate() == .secure {
            return .blockedSecureField
        }
        return copy(text, to: .general)
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard) -> InsertResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        pasteboard.clearContents()
        guard pasteboard.setString(trimmed, forType: .string) else {
            return .copyFailed
        }
        return .copied
    }

    private static func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        ifChangeCountIs ownedChangeCount: Int,
        after delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard pasteboard.changeCount == ownedChangeCount else { return }
            snapshot.restore(to: pasteboard)
        }
    }

    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

struct PasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restored = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
