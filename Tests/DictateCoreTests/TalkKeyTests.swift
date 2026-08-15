import Testing
@testable import DictateCore

@Test func onlyRightOptionStartsTalk() {
    #expect(!TalkKey.isPushToTalk(TalkKey.leftOption))
    #expect(TalkKey.isPushToTalk(TalkKey.rightOption))
    #expect(TalkKey.isOptionModifier(TalkKey.leftOption))
    #expect(TalkKey.isOptionModifier(TalkKey.rightOption))
}

@Test func nonOptionKeysDoNotStartTalk() {
    #expect(!TalkKey.isPushToTalk(0))
    #expect(!TalkKey.isPushToTalk(49))
    #expect(!TalkKey.isPushToTalk(TalkKey.escape))
}
