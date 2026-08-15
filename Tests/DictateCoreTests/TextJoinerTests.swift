import Testing
@testable import DictateCore

@Test func joinsLatinWordsWithSpace() {
    #expect(TextJoiner.join(["hello", "world"]) == "hello world")
}

@Test func joinsCJKWithoutSpace() {
    #expect(TextJoiner.join(["你好", "世界"]) == "你好世界")
}

@Test func joinsCJKThenLatinWithSpace() {
    #expect(TextJoiner.join(["把", "Sarah"]) == "把 Sarah")
}

@Test func joinsLatinThenCJKWithSpace() {
    #expect(TextJoiner.join(["hello", "世界"]) == "hello 世界")
}

@Test func joinsAfterSentencePunctuationWithSpace() {
    #expect(TextJoiner.join(["Done.", "Next"]) == "Done. Next")
}

@Test func skipsEmptyParts() {
    #expect(TextJoiner.join(["  ", "hello", "", "world"]) == "hello world")
}
