import Testing
@testable import DictateCore

@Test func partialsDoNotReceiveTranslation() {
    var session = DictateSession()
    session.begin()
    session.ingest(ASRHypothesis(text: "把", isFinal: false, t0: 0, t1: 0.3))
    session.setTranslation("put", for: SegmentID())

    #expect(session.committed.isEmpty)
    #expect(session.insertText.isEmpty)
    #expect(session.displayTranslation.isEmpty)
}

@Test func translationAttachesOnlyToFinalAndShowsInInsert() {
    var session = DictateSession()
    session.begin()
    let id = session.ingest(
        ASRHypothesis(text: "今天天气不错", isFinal: true, t0: 0, t1: 1.2)
    )!
    session.setTranslation("The weather is nice today.", for: id)

    #expect(session.committed.map(\.text) == ["今天天气不错"])
    #expect(session.committed[0].translation == "The weather is nice today.")
    #expect(session.displayText == "今天天气不错")
    #expect(session.displayTranslation == "The weather is nice today.")
    #expect(session.insertText == "今天天气不错\nThe weather is nice today.")
    #expect(session.sourceText == "今天天气不错")
}

@Test func laterPartialDoesNotClearTranslation() {
    var session = DictateSession()
    session.begin()
    let id = session.ingest(
        ASRHypothesis(text: "hello world", isFinal: true, t0: 0, t1: 1.0)
    )!
    session.setTranslation("你好世界", for: id)
    session.ingest(ASRHypothesis(text: "MUTATED", isFinal: false, t0: 1.0, t1: 1.4))

    #expect(session.committed[0].translation == "你好世界")
    #expect(session.insertText == "hello world\n你好世界")
}

@Test func twoFinalsKeepPairedTranslations() {
    var session = DictateSession()
    session.begin()
    let firstID = session.ingest(
        ASRHypothesis(text: "loop in Sarah", isFinal: true, t0: 0, t1: 1.0)
    )!
    let secondID = session.ingest(
        ASRHypothesis(text: "把这个 replicate 一下", isFinal: true, t0: 1.0, t1: 2.2)
    )!
    session.setTranslation("把 Sarah 拉进来", for: firstID)
    session.setTranslation("Replicate this.", for: secondID)

    #expect(
        session.insertText
            == "loop in Sarah\n把 Sarah 拉进来\n\n把这个 replicate 一下\nReplicate this."
    )
}

@Test func emptyTranslationIsIgnored() {
    var session = DictateSession()
    session.begin()
    let id = session.ingest(
        ASRHypothesis(text: "only source", isFinal: true, t0: 0, t1: 1.0)
    )!
    session.setTranslation("   ", for: id)
    #expect(session.committed[0].translation == nil)
    #expect(session.insertText == "only source")
}

@Test func cancelDropsTranslations() {
    var session = DictateSession()
    session.begin()
    let id = session.ingest(
        ASRHypothesis(text: "secret", isFinal: true, t0: 0, t1: 0.5)
    )!
    session.setTranslation("秘密", for: id)
    session.cancel()
    #expect(session.insertText.isEmpty)
    #expect(session.displayTranslation.isEmpty)
}
