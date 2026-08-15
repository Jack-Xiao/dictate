import Testing
@testable import DictateCore

@Test func partialsReplaceVolatileAndDoNotCommit() {
    var session = DictateSession()
    session.begin()
    session.ingest(ASRHypothesis(text: "把", isFinal: false, t0: 0, t1: 0.3))
    session.ingest(ASRHypothesis(text: "把 Sarah", isFinal: false, t0: 0, t1: 0.8))

    #expect(session.committed.isEmpty)
    #expect(session.partial == "把 Sarah")
    #expect(session.displayText == "把 Sarah")
    #expect(session.insertText.isEmpty)
}

@Test func finalCommitsAndClearsPartial() {
    var session = DictateSession()
    session.begin()
    session.ingest(ASRHypothesis(text: "把 Sarah", isFinal: false, t0: 0, t1: 0.8))
    session.ingest(ASRHypothesis(text: "把 Sarah loop in 一下", isFinal: true, t0: 0, t1: 2.1))

    #expect(session.committed.map(\.text) == ["把 Sarah loop in 一下"])
    #expect(session.partial.isEmpty)
    #expect(session.displayText == "把 Sarah loop in 一下")
    #expect(session.insertText == "把 Sarah loop in 一下")
}

@Test func laterPartialDoesNotMutateCommitted() {
    var session = DictateSession()
    session.begin()
    session.ingest(ASRHypothesis(text: "hello world", isFinal: true, t0: 0, t1: 1.2))
    session.ingest(ASRHypothesis(text: "HELLO MUTATED", isFinal: false, t0: 0.8, t1: 2.0))

    #expect(session.committed.map(\.text) == ["hello world"])
    #expect(session.partial == "HELLO MUTATED")
    #expect(session.displayText == "hello world HELLO MUTATED")
    #expect(session.insertText == "hello world")
}

@Test func finishCanExplicitlyIncludeDanglingPartial() {
    var session = DictateSession()
    session.begin()
    session.ingest(ASRHypothesis(text: "loop in Sarah", isFinal: true, t0: 0, t1: 1.5))
    session.ingest(ASRHypothesis(text: "把这个", isFinal: false, t0: 1.5, t1: 2.0))

    let text = session.finish(includeDanglingPartial: true)
    #expect(text == "loop in Sarah 把这个")
    #expect(session.phase == .idle)
    #expect(session.partial.isEmpty)
}

@Test func finishCanDropDanglingPartial() {
    var session = DictateSession()
    session.begin()
    session.ingest(ASRHypothesis(text: "keep", isFinal: true, t0: 0, t1: 0.5))
    session.ingest(ASRHypothesis(text: "drop me", isFinal: false, t0: 0.5, t1: 0.8))

    let text = session.finish()
    #expect(text == "keep")
}

@Test func cancelDiscardsEverythingAndInsertsNothing() {
    var session = DictateSession()
    session.begin()
    session.ingest(ASRHypothesis(text: "secret", isFinal: true, t0: 0, t1: 0.5))
    session.ingest(ASRHypothesis(text: "more", isFinal: false, t0: 0.5, t1: 0.8))
    session.cancel()

    #expect(session.phase == .idle)
    #expect(session.committed.isEmpty)
    #expect(session.partial.isEmpty)
    #expect(session.insertText.isEmpty)
    #expect(session.displayText.isEmpty)
}

@Test func emptyHypothesesAreIgnored() {
    var session = DictateSession()
    session.begin()
    session.ingest(ASRHypothesis(text: "   ", isFinal: false, t0: 0, t1: 0.1))
    session.ingest(ASRHypothesis(text: "", isFinal: true, t0: 0, t1: 0.2))
    session.ingest(ASRHypothesis(text: "\n", isFinal: true, t0: 0, t1: 0.3))
    #expect(session.committed.isEmpty)
    #expect(session.partial.isEmpty)
}

@Test func ingestBeforeBeginIsIgnored() {
    var session = DictateSession()
    session.ingest(ASRHypothesis(text: "too early", isFinal: true, t0: 0, t1: 0.4))
    #expect(session.committed.isEmpty)
}

@Test func overlappingFinalCorrectsEarlierTextInsteadOfAppending() {
    var session = DictateSession()
    session.begin()
    let originalID = session.ingest(
        ASRHypothesis(text: "今天下午三点", isFinal: true, t0: 0, t1: 1.4)
    )!
    session.setTranslation("at 3pm today", for: originalID)
    session.ingest(ASRHypothesis(text: "今天下午 3 点开会", isFinal: true, t0: 0, t1: 2.6))

    #expect(session.committed.map(\.text) == ["今天下午 3 点开会"])
    #expect(session.committed[0].translation == nil)
    #expect(session.displayText == "今天下午 3 点开会")
    #expect(session.insertText == "今天下午 3 点开会")
}

@Test func staleTranslationCannotAttachAfterFinalCorrection() {
    var session = DictateSession()
    session.begin()
    let oldID = session.ingest(
        ASRHypothesis(text: "turn left", isFinal: true, t0: 0, t1: 1.0)
    )!
    let correctedID = session.ingest(
        ASRHypothesis(text: "turn right", isFinal: true, t0: 0, t1: 1.4)
    )!

    session.setTranslation("向左转", for: oldID)
    session.setTranslation("向右转", for: correctedID)

    #expect(session.committed.map(\.text) == ["turn right"])
    #expect(session.committed[0].translation == "向右转")
}

@Test func draftStaysVisibleAlongsideEarlierFinals() {
    var session = DictateSession()
    session.begin()
    session.ingest(ASRHypothesis(text: "先把 Sarah loop in", isFinal: true, t0: 0, t1: 1.1))
    session.ingest(ASRHypothesis(text: "然后再", isFinal: false, t0: 1.1, t1: 1.6))
    session.ingest(ASRHypothesis(text: "然后再 replicate 一下", isFinal: false, t0: 1.1, t1: 2.4))

    #expect(session.committed.map(\.text) == ["先把 Sarah loop in"])
    #expect(session.partial == "然后再 replicate 一下")
    #expect(session.displayText == "先把 Sarah loop in 然后再 replicate 一下")
    #expect(session.insertText == "先把 Sarah loop in")
}
