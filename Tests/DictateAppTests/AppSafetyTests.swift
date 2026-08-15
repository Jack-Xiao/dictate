import AppKit
import Testing
@testable import dictate

@MainActor
@Test func pasteboardSnapshotRestoresEveryItemAndRepresentation() {
    let pasteboard = NSPasteboard(name: .init("dictate.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    let first = NSPasteboardItem()
    first.setString("plain", forType: .string)
    first.setData(Data("<b>rich</b>".utf8), forType: .html)
    let second = NSPasteboardItem()
    second.setString("second", forType: .string)
    pasteboard.writeObjects([first, second])

    let snapshot = PasteboardSnapshot.capture(from: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("temporary dictation", forType: .string)
    snapshot.restore(to: pasteboard)

    let restored = pasteboard.pasteboardItems ?? []
    #expect(restored.count == 2)
    #expect(restored[0].string(forType: .string) == "plain")
    #expect(restored[0].data(forType: .html) == Data("<b>rich</b>".utf8))
    #expect(restored[1].string(forType: .string) == "second")
}

@MainActor
@Test func copyModeWritesTrimmedTextToPasteboard() {
    let pasteboard = NSPasteboard(name: .init("dictate.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    let result = PasteInserter.copy("  中英 clipboard test  \n", to: pasteboard)

    #expect(result == .copied)
    #expect(pasteboard.string(forType: .string) == "中英 clipboard test")
}

@MainActor
@Test func copyModeRejectsEmptyTextWithoutChangingPasteboard() {
    let pasteboard = NSPasteboard(name: .init("dictate.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("keep", forType: .string)

    let result = PasteInserter.copy(" \n ", to: pasteboard)

    #expect(result == .empty)
    #expect(pasteboard.string(forType: .string) == "keep")
}

@available(macOS 26.0, *)
@Test func languageDetectionOverridesConfiguredASRLocale() {
    #expect(
        AppleTranslator.resolveSource(
            text: "This is an English sentence with enough context.",
            hinted: "zh-CN"
        ) == "en"
    )
    #expect(
        AppleTranslator.resolveSource(
            text: "这是一个用于语言检测的中文句子。",
            hinted: "en-US"
        ).hasPrefix("zh")
    )
}

@available(macOS 26.0, *)
@Test func releaseBeforeRunnerStartsCompletesWithoutOpeningInput() async throws {
    let runner = SpeechRunner()
    await runner.requestFinish()
    try await runner.finish()
}

@available(macOS 26.0, *)
@Test func cancelBeforeRunnerStartsIsIdempotent() async {
    let runner = SpeechRunner()
    await runner.cancel()
    await runner.cancel()
}
