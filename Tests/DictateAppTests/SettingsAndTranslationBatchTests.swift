import DictateCore
import Foundation
import Testing
@testable import dictate

@Test func settingsDefaultToChineseWithTranslationEnabled() {
    let suite = "dictate.settings.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    let settings = DictateSettings.load(defaults: defaults)

    #expect(settings.localeIdentifier == "zh-CN")
    #expect(settings.translationEnabled)
    #expect(settings.commitMode == .insert)
}

@Test func settingsPersistAndAllowLaunchOverrides() {
    let suite = "dictate.settings.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    DictateSettings(
        localeIdentifier: "en-US",
        translationEnabled: false,
        commitMode: .copy
    ).save(to: defaults)

    #expect(DictateSettings.load(defaults: defaults).localeIdentifier == "en-US")
    #expect(!DictateSettings.load(defaults: defaults).translationEnabled)
    #expect(DictateSettings.load(defaults: defaults).commitMode == .copy)
    #expect(
        DictateSettings.load(
            defaults: defaults,
            localeOverride: "zh-CN",
            translationOverride: true,
            commitModeOverride: .insert
        ) == DictateSettings(
            localeIdentifier: "zh-CN",
            translationEnabled: true,
            commitMode: .insert
        )
    )
}

@Test func cliCanOverrideRecognitionLanguageAndTranslation() {
    let options = parseArgs(["--locale", "en-US", "--no-translate", "--copy"])
    #expect(options.locale == "en-US")
    #expect(options.translationEnabled == false)
    #expect(options.commitMode == .copy)

    let enabled = parseArgs(["--translate", "--insert"])
    #expect(enabled.translationEnabled == true)
    #expect(enabled.commitMode == .insert)

    let preview = parseArgs(["--preview-hud"])
    #expect(preview.previewHUD)
}

@MainActor
@Test func translationBatchCompletesWhenAllSegmentsFinish() async {
    let batch = TranslationBatch()
    let first = SegmentID()
    let second = SegmentID()
    batch.add(first)
    batch.add(second)

    Task { @MainActor in
        batch.complete(first)
        batch.complete(second)
    }

    #expect(await batch.wait(timeoutNanoseconds: 1_000_000_000) == .completed)
}

@MainActor
@Test func translationBatchTimeoutDoesNotWaitForPendingWork() async {
    let batch = TranslationBatch()
    batch.add(SegmentID())
    let clock = ContinuousClock()
    let start = clock.now

    let outcome = await batch.wait(timeoutNanoseconds: 20_000_000)

    #expect(outcome == .timedOut)
    #expect(start.duration(to: clock.now) < .milliseconds(250))
}

@MainActor
@Test func translationBatchCancellationReleasesWaiter() async {
    let batch = TranslationBatch()
    batch.add(SegmentID())

    Task { @MainActor in batch.cancel() }

    #expect(await batch.wait(timeoutNanoseconds: 1_000_000_000) == .cancelled)
}
