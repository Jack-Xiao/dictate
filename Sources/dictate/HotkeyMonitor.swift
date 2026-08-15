import ApplicationServices
@preconcurrency import CoreGraphics
import DictateCore
import Foundation

/// Right Option starts Chinese dictation and Fn starts English dictation. A
/// short tap or a modifier shortcut does not start dictation. Escape cancels
/// keyboard- or menu-started utterances.
@MainActor
final class HotkeyMonitor {
    private enum Callback: Sendable {
        case talkDown(TalkKey.Route)
        case talkUp
        case cancel
    }

    var onTalkDown: ((TalkKey.Route) -> Void)?
    var onTalkUp: (() -> Void)?
    var onCancel: (() -> Void)?
    var isTalkActive: (() -> Bool)?

    private let holdThreshold: TimeInterval = 0.16
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activationWorkItem: DispatchWorkItem?
    private var gesture = TalkGesture()
    private var activeKeycode: Int64?
    private var activeRoute: TalkKey.Route?

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
        clearTrigger()
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
            clearTrigger()
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
            clearTrigger()
            dispatchCallback(.cancel)
            return nil
        }

        if type == .keyDown, gesture.phase == .pending || gesture.phase == .talking {
            apply(gesture.otherKeyPressed())
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged, let route = TalkKey.route(for: keycode) else {
            return Unmanaged.passUnretained(event)
        }

        let isDown: Bool
        switch route {
        case .chinese:
            isDown = CGEventSource.keyState(
                .combinedSessionState,
                key: CGKeyCode(TalkKey.rightOption)
            )
        case .english:
            isDown = event.flags.contains(.maskSecondaryFn)
        }

        if isDown {
            guard activeKeycode == nil else {
                return Unmanaged.passUnretained(event)
            }
            activeKeycode = keycode
            activeRoute = route
        } else {
            guard activeKeycode == keycode else {
                return Unmanaged.passUnretained(event)
            }
        }

        apply(gesture.optionChanged(isDown: isDown))
        if !isDown {
            clearTrigger()
        }
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
                if let activeRoute {
                    dispatchCallback(.talkDown(activeRoute))
                }
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
            case .talkDown(let route):
                self?.onTalkDown?(route)
            case .talkUp:
                self?.onTalkUp?()
            case .cancel:
                self?.onCancel?()
            }
        }
    }

    private func clearTrigger() {
        activeKeycode = nil
        activeRoute = nil
    }
}
