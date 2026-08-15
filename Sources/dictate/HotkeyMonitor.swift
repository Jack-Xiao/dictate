import ApplicationServices
@preconcurrency import CoreGraphics
import DictateCore
import Foundation

/// Right Option hold-to-talk. A short tap or an Option shortcut does not start
/// dictation. Escape cancels keyboard- or menu-started utterances.
@MainActor
final class HotkeyMonitor {
    private enum Callback: Sendable {
        case talkDown
        case talkUp
        case cancel
    }

    var onTalkDown: (() -> Void)?
    var onTalkUp: (() -> Void)?
    var onCancel: (() -> Void)?
    var isTalkActive: (() -> Bool)?

    private let holdThreshold: TimeInterval = 0.16
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activationWorkItem: DispatchWorkItem?
    private var gesture = TalkGesture()

    func start() -> Bool {
        stop()
        let mask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.tapDisabledByTimeout.rawValue)
            | (CGEventMask(1) << CGEventType.tapDisabledByUserInput.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    monitor.handle(type: type, event: event)
                }
            },
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        apply(gesture.reset(cancelActive: false))
    }

    func requestAccessibilityPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue as Any] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let actions = gesture.reset(cancelActive: true)
            let gestureAlreadyCancels = actions.contains(.cancelTalk)
            apply(actions)
            if !gestureAlreadyCancels, isTalkActive?() ?? false {
                dispatchCallback(.cancel)
            }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown, keycode == TalkKey.escape,
           gesture.phase == .talking || (isTalkActive?() ?? false)
        {
            apply(gesture.reset(cancelActive: false))
            dispatchCallback(.cancel)
            return nil
        }

        if type == .keyDown, gesture.phase == .pending || gesture.phase == .talking {
            apply(gesture.otherKeyPressed())
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged, TalkKey.isPushToTalk(keycode) else {
            return Unmanaged.passUnretained(event)
        }

        let isDown = CGEventSource.keyState(
            .combinedSessionState,
            key: CGKeyCode(TalkKey.rightOption)
        )
        apply(gesture.optionChanged(isDown: isDown))
        return Unmanaged.passUnretained(event)
    }

    private func apply(_ actions: [TalkGesture.Action]) {
        for action in actions {
            switch action {
            case .scheduleActivation:
                scheduleActivation()
            case .cancelScheduledActivation:
                activationWorkItem?.cancel()
                activationWorkItem = nil
            case .startTalk:
                dispatchCallback(.talkDown)
            case .stopTalk:
                dispatchCallback(.talkUp)
            case .cancelTalk:
                dispatchCallback(.cancel)
            }
        }
    }

    private func scheduleActivation() {
        activationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activationWorkItem = nil
            self.apply(self.gesture.activationTimerFired())
        }
        activationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
    }

    private func dispatchCallback(_ callback: Callback) {
        DispatchQueue.main.async { [weak self] in
            switch callback {
            case .talkDown:
                self?.onTalkDown?()
            case .talkUp:
                self?.onTalkUp?()
            case .cancel:
                self?.onCancel?()
            }
        }
    }
}
