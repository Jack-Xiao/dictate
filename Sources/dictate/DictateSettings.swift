import Foundation

enum DictateCommitMode: String, Equatable, Sendable {
    case insert
    case copy
}

struct DictateSettings: Equatable {
    static let localeKey = "recognitionLocaleIdentifier"
    static let translationKey = "translationEnabled"
    static let commitModeKey = "commitMode"

    var localeIdentifier: String
    var translationEnabled: Bool
    var commitMode: DictateCommitMode

    static func load(
        defaults: UserDefaults = .standard,
        localeOverride: String? = nil,
        translationOverride: Bool? = nil,
        commitModeOverride: DictateCommitMode? = nil
    ) -> DictateSettings {
        let storedLocale = defaults.string(forKey: localeKey)
        let storedTranslation = defaults.object(forKey: translationKey) as? Bool
        let storedCommitMode = defaults.string(forKey: commitModeKey)
            .flatMap(DictateCommitMode.init(rawValue:))
        return DictateSettings(
            localeIdentifier: localeOverride ?? storedLocale ?? "zh-CN",
            translationEnabled: translationOverride ?? storedTranslation ?? true,
            commitMode: commitModeOverride ?? storedCommitMode ?? .insert
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(localeIdentifier, forKey: Self.localeKey)
        defaults.set(translationEnabled, forKey: Self.translationKey)
        defaults.set(commitMode.rawValue, forKey: Self.commitModeKey)
    }
}
