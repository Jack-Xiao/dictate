import Testing
@testable import DictateCore

@Test func quickOptionTapNeverStartsTalk() {
    var gesture = TalkGesture()
    #expect(gesture.optionChanged(isDown: true) == [.scheduleActivation])
    #expect(gesture.optionChanged(isDown: false) == [.cancelScheduledActivation])
    #expect(gesture.activationTimerFired().isEmpty)
    #expect(gesture.phase == .idle)
}

@Test func heldOptionStartsThenStopsExactlyOnce() {
    var gesture = TalkGesture()
    _ = gesture.optionChanged(isDown: true)
    #expect(gesture.activationTimerFired() == [.startTalk])
    #expect(gesture.activationTimerFired().isEmpty)
    #expect(gesture.optionChanged(isDown: false) == [.stopTalk])
    #expect(gesture.phase == .idle)
}

@Test func optionShortcutSuppressesDictationUntilRelease() {
    var gesture = TalkGesture()
    _ = gesture.optionChanged(isDown: true)
    #expect(gesture.otherKeyPressed() == [.cancelScheduledActivation])
    #expect(gesture.activationTimerFired().isEmpty)
    #expect(gesture.optionChanged(isDown: true).isEmpty)
    #expect(gesture.optionChanged(isDown: false) == [.cancelScheduledActivation])
    #expect(gesture.phase == .idle)
}

@Test func keyPressedAfterActivationCancelsInsteadOfCommitting() {
    var gesture = TalkGesture()
    _ = gesture.optionChanged(isDown: true)
    _ = gesture.activationTimerFired()
    #expect(gesture.otherKeyPressed() == [.cancelTalk])
    #expect(gesture.optionChanged(isDown: false) == [.cancelScheduledActivation])
    #expect(gesture.phase == .idle)
}

@Test func eventTapResetCancelsActiveTalk() {
    var gesture = TalkGesture()
    _ = gesture.optionChanged(isDown: true)
    _ = gesture.activationTimerFired()
    #expect(gesture.reset(cancelActive: true) == [.cancelTalk])
    #expect(gesture.phase == .idle)
}
