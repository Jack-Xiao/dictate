import Foundation
import NaturalLanguage
#if canImport(Translation)
@preconcurrency import Translation
#endif

protocol Translating: Sendable {
    func translate(_ text: String, sourceLang: String?) async throws -> String
}

/// On-device Apple Translation. Reuses one session so each FINAL is not paying prepare cost again.
@available(macOS 26.0, *)
actor AppleTranslator: Translating {
    var forcedTarget: String?
    private var prepared: TranslationSession?
    private var preparedPair: (String, String)?
    private var translating = false
    private var translationWaiters: [CheckedContinuation<Void, Never>] = []

    func translate(_ text: String, sourceLang: String?) async throws -> String {
        await acquireTranslationSlot()
        defer { releaseTranslationSlot() }
        try Task.checkCancellation()

        let sourceID = Self.resolveSource(text: text, hinted: sourceLang)
        let targetID = Self.resolveTarget(sourceID: sourceID, forced: forcedTarget)

        let session = try await preparedSession(sourceID: sourceID, targetID: targetID)
        let response = try await session.translate(text)
        let out = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty {
            throw SpeechError.unavailable("翻译结果为空 \(sourceID)→\(targetID)")
        }
        return out
    }

    private func acquireTranslationSlot() async {
        if !translating {
            translating = true
            return
        }
        await withCheckedContinuation { continuation in
            translationWaiters.append(continuation)
        }
    }

    private func releaseTranslationSlot() {
        if translationWaiters.isEmpty {
            translating = false
        } else {
            translationWaiters.removeFirst().resume()
        }
    }

    private func preparedSession(sourceID: String, targetID: String) async throws -> TranslationSession {
        if let prepared, preparedPair?.0 == sourceID, preparedPair?.1 == targetID {
            return prepared
        }

        let availability = LanguageAvailability()
        let source = Locale.Language(identifier: sourceID)
        let target = Locale.Language(identifier: targetID)
        let status = await availability.status(from: source, to: target)
        switch status {
        case .unsupported:
            throw SpeechError.unavailable("不支持翻译 \(sourceID)→\(targetID)")
        case .supported:
            throw SpeechError.unavailable("未安装翻译 \(sourceID)→\(targetID)")
        case .installed:
            break
        @unknown default:
            throw SpeechError.unavailable("翻译状态未知 \(sourceID)→\(targetID)")
        }

        let session = TranslationSession(installedSource: source, target: target)
        try await session.prepareTranslation()
        prepared = session
        preparedPair = (sourceID, targetID)
        return session
    }

    static func resolveSource(text: String, hinted: String?) -> String {
        if let dominant = detect(text) {
            return dominant
        }
        if text.contains(where: { $0 >= "\u{4E00}" && $0 <= "\u{9FFF}" }) {
            return "zh-Hans"
        }
        if let hinted, let mapped = mapLang(hinted) {
            return mapped
        }
        return "en"
    }

    static func resolveTarget(sourceID: String, forced: String?) -> String {
        if let forced, let mapped = mapLang(forced) {
            return mapped
        }
        return sourceID.hasPrefix("zh") ? "en" : "zh-Hans"
    }

    static func mapLang(_ raw: String) -> String? {
        let lower = raw.replacingOccurrences(of: "_", with: "-").lowercased()
        if lower.hasPrefix("zh") { return "zh-Hans" }
        if lower.hasPrefix("en") { return "en" }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("ko") { return "ko" }
        return raw
    }

    static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }
        return mapLang(lang.rawValue)
    }
}
