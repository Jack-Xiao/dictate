import Testing
@testable import DictateCore

@Test func rightOptionAndFunctionRouteToSeparateLanguages() {
    #expect(!TalkKey.isPushToTalk(TalkKey.leftOption))
    #expect(TalkKey.isPushToTalk(TalkKey.rightOption))
    #expect(TalkKey.isPushToTalk(TalkKey.function))
    #expect(TalkKey.isOptionModifier(TalkKey.leftOption))
    #expect(TalkKey.isOptionModifier(TalkKey.rightOption))
    #expect(TalkKey.route(for: TalkKey.rightOption) == .chinese)
    #expect(TalkKey.route(for: TalkKey.function) == .english)
    #expect(TalkKey.Route.chinese.localeIdentifier == "zh-CN")
    #expect(TalkKey.Route.english.localeIdentifier == "en-US")
}

@Test func nonOptionKeysDoNotStartTalk() {
    #expect(!TalkKey.isPushToTalk(0))
    #expect(!TalkKey.isPushToTalk(49))
    #expect(!TalkKey.isPushToTalk(TalkKey.escape))
}
