import AppKit
import AVFoundation
import DictateCore

@available(macOS 26.0, *)
@MainActor
private final class UtteranceTransaction {
    let id = UUID()
    let runner = SpeechRunner()
    let target: TargetSnapshot?
    let localeIdentifier: String
    let translationEnabled: Bool
    let commitMode: DictateCommitMode
    let translator: AppleTranslator?
    let translationBatch = TranslationBatch()
    var session = DictateSession()
    var startTask: Task<Void, Never>?
    var translationTasks: [SegmentID: Task<Void, Never>] = [:]
    var translationFailure: String?

    init(
        target: TargetSnapshot?,
        localeIdentifier: String,
        translationEnabled: Bool,
        commitMode: DictateCommitMode,
        translator: AppleTranslator?
    ) {
        self.target = target
        self.localeIdentifier = localeIdentifier
        self.translationEnabled = translationEnabled
        self.commitMode = commitMode
        self.translator = translator
        session.begin()
    }

    func addTranslationTask(_ task: Task<Void, Never>, for id: SegmentID) {
        translationTasks[id]?.cancel()
        translationBatch.add(id)
        translationTasks[id] = task
    }

    func translationFinished(_ id: SegmentID) {
        translationTasks[id] = nil
        translationBatch.complete(id)
    }

    func pruneTranslations(keeping ids: Set<SegmentID>) {
        for id in Array(translationTasks.keys) where !ids.contains(id) {
            translationTasks[id]?.cancel()
            translationTasks[id] = nil
            translationBatch.remove(id)
        }
    }

    func waitForTranslations(timeoutNanoseconds: UInt64) async -> TranslationBatch.Outcome {
        await translationBatch.wait(timeoutNanoseconds: timeoutNanoseconds)
    }

    func discardOutstandingTranslations() {
        translationTasks.values.forEach { $0.cancel() }
        translationTasks.removeAll()
    }

    func cancelTranslations() {
        discardOutstandingTranslations()
        translationBatch.cancel()
    }
}

@available(macOS 26.0, *)
@MainActor
final class AppController: NSObject, NSMenuItemValidation {
    private let overlay = OverlayPanel()
    private let hotkey = HotkeyMonitor()
    private var active: UtteranceTransaction?
    private var statusItem: NSStatusItem?
    private var preheatTask: Task<Void, Never>?
    private var chineseMenuItem: NSMenuItem?
    private var englishMenuItem: NSMenuItem?
    private var translationMenuItem: NSMenuItem?
    private var insertMenuItem: NSMenuItem?
    private var copyMenuItem: NSMenuItem?
    private var copyLastMenuItem: NSMenuItem?
    private var lastPayload: String?
    private var settings = DictateSettings(
        localeIdentifier: "zh-CN",
        translationEnabled: true,
        commitMode: .insert
    )
    private var translator: AppleTranslator?

    private var localeIdentifier: String { settings.localeIdentifier }
    private var translationEnabled: Bool { settings.translationEnabled }
    private var commitMode: DictateCommitMode { settings.commitMode }

    func start(
        localeIdentifier: String?,
        translationEnabled: Bool?,
        commitMode: DictateCommitMode?,
        previewHUD: Bool = false
    ) {
        settings = DictateSettings.load(
            localeOverride: localeIdentifier,
            translationOverride: translationEnabled,
            commitModeOverride: commitMode
        )
        translator = settings.translationEnabled ? AppleTranslator() : nil

        installStatusItem()
        hotkey.onTalkDown = { [weak self] route in
            self?.beginTalk(localeIdentifier: route.localeIdentifier)
        }
        hotkey.onTalkUp = { [weak self] in self?.endTalk() }
        hotkey.onCancel = { [weak self] in self?.cancelTalk() }
        hotkey.isTalkActive = { [weak self] in self?.active != nil }

        let tapOK = hotkey.start()
        if !tapOK || !hotkey.isTrusted {
            hotkey.requestAccessibilityPrompt()
            overlay.showMessage(
                "请到「系统设置 → 隐私与安全性」打开 Dictate 的「辅助功能」和「输入监控」。也可以先点菜单栏麦克风开始听写。"
            )
            overlay.hide(after: 10)
        }

        preheatRecognitionModels()
        if previewHUD {
            overlay.showPreview()
        }
    }

    private func preheatRecognitionModels() {
        preheatTask?.cancel()
        preheatTask = Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted, !Task.isCancelled else { return }
            await SpeechRunner.preheatModels(localeIdentifiers: ["zh-CN", "en-US"])
        }
    }

    private func beginTalk(localeIdentifier override: String? = nil) {
        if let previous = active {
            abandon(previous)
        }

        let transaction = UtteranceTransaction(
            target: TargetSnapshot.capture(),
            localeIdentifier: override ?? localeIdentifier,
            translationEnabled: translationEnabled,
            commitMode: commitMode,
            translator: translator
        )
        active = transaction
        overlay.show(
            session: transaction.session,
            status: listeningStatus(for: transaction),
            localeIdentifier: transaction.localeIdentifier
        )

        let task = Task { [weak self, weak transaction] in
            guard let self, let transaction else { return }
            let granted = await AVAudioApplication.requestRecordPermission()
            guard !Task.isCancelled, self.isCurrent(transaction, phase: .listening) else { return }
            guard granted else {
                self.fail(transaction, message: "没有麦克风权限")
                return
            }

            do {
                try await transaction.runner.start(
                    localeIdentifier: transaction.localeIdentifier,
                    onAudioLevel: { [weak self, weak transaction] level in
                        MainActor.assumeIsolated {
                            guard let self, let transaction, self.isCurrent(transaction) else {
                                return
                            }
                            self.overlay.updateAudioLevel(level)
                        }
                    },
                    onHypothesis: { [weak self, weak transaction] hypothesis in
                        MainActor.assumeIsolated {
                            guard let self, let transaction else { return }
                            self.ingest(hypothesis, into: transaction)
                        }
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.isCurrent(transaction, phase: .listening) else {
                    return
                }
                self.fail(transaction, message: String(describing: error))
            }
        }
        transaction.startTask = task
    }

    private func ingest(_ hypothesis: ASRHypothesis, into transaction: UtteranceTransaction) {
        guard isCurrent(transaction) else { return }
        let segmentID = transaction.session.ingest(hypothesis)
        transaction.pruneTranslations(keeping: Set(transaction.session.committed.map(\.id)))
        if hypothesis.isFinal, let segmentID,
           let line = transaction.session.committed.first(where: { $0.id == segmentID })
        {
            scheduleTranslation(
                text: line.text,
                segmentID: segmentID,
                transaction: transaction
            )
        }
        overlay.show(
            session: transaction.session,
            status: listeningStatus(for: transaction),
            localeIdentifier: transaction.localeIdentifier
        )
    }

    private func endTalk() {
        guard let transaction = active, transaction.session.phase == .listening else { return }
        transaction.session.markStopping()
        overlay.updateAudioLevel(0)
        overlay.show(
            session: transaction.session,
            status: "正在收尾…",
            localeIdentifier: transaction.localeIdentifier
        )

        Task { [weak self, weak transaction] in
            guard let self, let transaction else { return }
            await transaction.runner.requestFinish()
            transaction.startTask?.cancel()
            await transaction.startTask?.value

            do {
                try await transaction.runner.finish()
            } catch {
                guard self.isCurrent(transaction) else { return }
                self.fail(transaction, message: "识别收尾失败：\(error)")
                return
            }

            guard self.isCurrent(transaction, phase: .stopping) else { return }
            var translationOutcome: TranslationBatch.Outcome = .completed
            if transaction.translationEnabled {
                self.overlay.show(
                    session: transaction.session,
                    status: "正在翻译…",
                    localeIdentifier: transaction.localeIdentifier
                )
                translationOutcome = await transaction.waitForTranslations(
                    timeoutNanoseconds: 2_000_000_000
                )
                guard self.isCurrent(transaction, phase: .stopping) else { return }
                if translationOutcome == .timedOut {
                    transaction.discardOutstandingTranslations()
                    if self.translator === transaction.translator {
                        self.translator = AppleTranslator()
                    }
                }
            }

            _ = transaction.session.finish(includeDanglingPartial: false)
            let payload = transaction.translationEnabled
                ? transaction.session.insertText
                : transaction.session.sourceText
            let translationNote = self.translationNote(
                for: transaction,
                outcome: translationOutcome
            )
            let result: InsertResult = switch transaction.commitMode {
            case .insert:
                PasteInserter.insert(payload, into: transaction.target)
            case .copy:
                PasteInserter.copy(payload, respecting: transaction.target)
            }
            guard self.active === transaction else { return }
            self.active = nil
            transaction.discardOutstandingTranslations()
            switch result {
            case .empty, .blockedSecureField, .copyFailed:
                break
            case .directInserted, .pasteAttempted, .copied, .copiedTargetChanged, .copiedOnly:
                self.lastPayload = payload
                self.refreshSettingsMenu()
            }
            self.present(result, translationNote: translationNote)
        }
    }

    private func cancelTalk() {
        guard let transaction = active else { return }
        active = nil
        transaction.cancelTranslations()
        transaction.session.cancel()
        overlay.hide()

        Task {
            await transaction.runner.cancel()
            transaction.startTask?.cancel()
            await transaction.startTask?.value
        }
    }

    private func abandon(_ transaction: UtteranceTransaction) {
        if active === transaction {
            active = nil
        }
        transaction.cancelTranslations()
        transaction.session.cancel()
        Task {
            await transaction.runner.cancel()
            transaction.startTask?.cancel()
            await transaction.startTask?.value
        }
    }

    private func scheduleTranslation(
        text: String,
        segmentID: SegmentID,
        transaction: UtteranceTransaction
    ) {
        guard transaction.translationEnabled, let translator = transaction.translator else { return }

        let task = Task { [weak self, weak transaction] in
            defer { transaction?.translationFinished(segmentID) }
            do {
                let translated = try await translator.translate(text, sourceLang: nil)
                guard !Task.isCancelled,
                      let self,
                      let transaction,
                      self.isCurrent(transaction)
                else {
                    return
                }
                transaction.session.setTranslation(translated, for: segmentID)
                self.overlay.show(
                    session: transaction.session,
                    status: self.listeningStatus(for: transaction),
                    localeIdentifier: transaction.localeIdentifier
                )
            } catch {
                guard !Task.isCancelled,
                      let self,
                      let transaction,
                      self.isCurrent(transaction)
                else {
                    return
                }
                transaction.translationFailure = String(describing: error)
            }
        }
        transaction.addTranslationTask(task, for: segmentID)
    }

    private func listeningStatus(for transaction: UtteranceTransaction) -> String {
        transaction.translationEnabled
            ? "正在听…  灰色为草稿，定稿后翻译"
            : "正在听…  灰色为草稿"
    }

    private func isCurrent(
        _ transaction: UtteranceTransaction,
        phase: DictateSession.Phase? = nil
    ) -> Bool {
        guard active === transaction else { return false }
        guard let phase else { return true }
        return transaction.session.phase == phase
    }

    private func fail(_ transaction: UtteranceTransaction, message: String) {
        guard active === transaction else { return }
        active = nil
        transaction.startTask?.cancel()
        transaction.cancelTranslations()
        transaction.session.cancel()
        overlay.showMessage(message)
        overlay.hide(after: 2.4)
        Task {
            await transaction.runner.cancel()
        }
    }

    private func translationNote(
        for transaction: UtteranceTransaction,
        outcome: TranslationBatch.Outcome
    ) -> String? {
        guard transaction.translationEnabled else { return nil }
        let total = transaction.session.committed.count
        guard total > 0 else { return nil }
        let translated = transaction.session.committed.count { $0.translation != nil }
        if translated == total {
            return "已包含译文"
        }
        if translated > 0 {
            return "部分句子已翻译，其余保留原文"
        }
        if outcome == .timedOut {
            return "翻译超时，已安全回退为原文"
        }
        if let failure = transaction.translationFailure {
            return "翻译不可用，已回退原文：\(failure)"
        }
        return "没有生成译文，已回退原文"
    }

    private func present(_ result: InsertResult, translationNote: String?) {
        let note = translationNote.map { "\n\($0)" } ?? ""
        switch result {
        case .empty:
            overlay.showMessage("没有识别到定稿文字")
            overlay.hide(after: 0.9)
        case .directInserted:
            overlay.showMessage("已写入原输入框\(note)")
            overlay.hide(after: translationNote == nil ? 0.45 : 1.5)
        case .pasteAttempted:
            overlay.showMessage("已发送到原输入框\(note)")
            overlay.hide(after: translationNote == nil ? 0.5 : 1.5)
        case .copied:
            overlay.showMessage("已复制到剪贴板\(note)")
            overlay.hide(after: translationNote == nil ? 0.9 : 1.5)
        case .copiedTargetChanged:
            overlay.showMessage("焦点已变化，未自动粘贴；文字已复制\(note)")
            overlay.hide(after: 2.4)
        case .copiedOnly:
            overlay.showMessage("无法验证原输入框；文字已复制，请手动 ⌘V\(note)")
            overlay.hide(after: 2.4)
        case .copyFailed:
            overlay.showMessage("写入剪贴板失败")
            overlay.hide(after: 1.8)
        case .blockedSecureField:
            overlay.showMessage("安全输入框不自动插入，也未写入剪贴板")
            overlay.hide(after: 2.4)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictate")
            button.toolTip = "Dictate：右 Option 中文，Fn English"
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(
            title: "开始 / 停止听写",
            action: #selector(toggleTalk),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(withTitle: "按住右 Option：中文（可夹英文）", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "按住 Fn：English", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Esc 取消当前识别", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "预览刘海 HUD", action: #selector(previewHUD), keyEquivalent: "")
        menu.addItem(.separator())

        let languageItem = NSMenuItem(title: "识别语言", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: "识别语言")
        let chinese = NSMenuItem(
            title: "中文（可夹英文）",
            action: #selector(selectChineseRecognition),
            keyEquivalent: ""
        )
        let english = NSMenuItem(
            title: "English",
            action: #selector(selectEnglishRecognition),
            keyEquivalent: ""
        )
        chinese.target = self
        english.target = self
        languageMenu.addItem(chinese)
        languageMenu.addItem(english)
        menu.setSubmenu(languageMenu, for: languageItem)
        menu.addItem(languageItem)
        chineseMenuItem = chinese
        englishMenuItem = english

        let commitItem = NSMenuItem(title: "完成方式", action: nil, keyEquivalent: "")
        let commitMenu = NSMenu(title: "完成方式")
        let insert = NSMenuItem(
            title: "插入原输入框",
            action: #selector(selectInsertMode),
            keyEquivalent: ""
        )
        let copy = NSMenuItem(
            title: "只复制到剪贴板",
            action: #selector(selectCopyMode),
            keyEquivalent: ""
        )
        insert.target = self
        copy.target = self
        commitMenu.addItem(insert)
        commitMenu.addItem(copy)
        menu.setSubmenu(commitMenu, for: commitItem)
        menu.addItem(commitItem)
        insertMenuItem = insert
        copyMenuItem = copy

        let copyLast = NSMenuItem(
            title: "复制上次听写结果",
            action: #selector(copyLastResult),
            keyEquivalent: ""
        )
        copyLast.target = self
        menu.addItem(copyLast)
        copyLastMenuItem = copyLast

        let translation = NSMenuItem(
            title: "附带本地翻译（原文 + 译文）",
            action: #selector(toggleTranslation),
            keyEquivalent: ""
        )
        translation.target = self
        menu.addItem(translation)
        translationMenuItem = translation
        menu.addItem(
            withTitle: "打开翻译语言设置",
            action: #selector(openTranslationLanguages),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开辅助功能设置", action: #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(withTitle: "打开麦克风设置", action: #selector(openMicrophone), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Dictate", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
        refreshSettingsMenu()
    }

    private func refreshSettingsMenu() {
        chineseMenuItem?.state = localeIdentifier.lowercased().hasPrefix("zh") ? .on : .off
        englishMenuItem?.state = localeIdentifier.lowercased().hasPrefix("en") ? .on : .off
        translationMenuItem?.state = translationEnabled ? .on : .off
        insertMenuItem?.state = commitMode == .insert ? .on : .off
        copyMenuItem?.state = commitMode == .copy ? .on : .off
        copyLastMenuItem?.isEnabled = lastPayload != nil
        let destination = commitMode == .insert ? "插入" : "复制"
        let translation = translationEnabled ? "，含翻译" : ""
        statusItem?.button?.toolTip = "Dictate：右 Option 中文 / Fn English（菜单启动：\(localeIdentifier)，\(destination)\(translation)）"
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyLastResult) {
            return lastPayload != nil
        }
        return true
    }

    private func applyLanguage(_ localeIdentifier: String, title: String) {
        if active != nil { cancelTalk() }
        settings.localeIdentifier = localeIdentifier
        settings.save()
        refreshSettingsMenu()
        preheatRecognitionModels()
        overlay.showMessage("识别语言已切换为 \(title)")
        overlay.hide(after: 1.2)
    }

    @objc private func selectChineseRecognition() {
        applyLanguage("zh-CN", title: "中文（可夹英文）")
    }

    @objc private func selectEnglishRecognition() {
        applyLanguage("en-US", title: "English")
    }

    private func applyCommitMode(_ mode: DictateCommitMode) {
        if active != nil { cancelTalk() }
        settings.commitMode = mode
        settings.save()
        refreshSettingsMenu()
        let title = mode == .insert ? "插入原输入框" : "只复制到剪贴板"
        overlay.showMessage("完成方式：\(title)")
        overlay.hide(after: 1.2)
    }

    @objc private func selectInsertMode() {
        applyCommitMode(.insert)
    }

    @objc private func selectCopyMode() {
        applyCommitMode(.copy)
    }

    @objc private func copyLastResult() {
        guard let lastPayload else { return }
        present(PasteInserter.copy(lastPayload, to: .general), translationNote: nil)
    }

    @objc private func toggleTranslation() {
        if active != nil { cancelTalk() }
        settings.translationEnabled.toggle()
        settings.save()
        translator = translationEnabled ? AppleTranslator() : nil
        refreshSettingsMenu()
        overlay.showMessage(translationEnabled ? "翻译已开启：将提交原文 + 译文" : "翻译已关闭：只提交原文")
        overlay.hide(after: 1.5)
    }

    @objc private func openTranslationLanguages() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func previewHUD() {
        if active != nil { cancelTalk() }
        overlay.showPreview()
        overlay.hide(after: 6)
    }

    @objc private func openAccessibility() {
        hotkey.requestAccessibilityPrompt()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openMicrophone() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleTalk() {
        guard let active else {
            beginTalk()
            return
        }
        switch active.session.phase {
        case .listening:
            endTalk()
        case .stopping:
            cancelTalk()
        case .idle:
            beginTalk()
        }
    }

    @objc private func quit() {
        preheatTask?.cancel()
        cancelTalk()
        NSApp.terminate(nil)
    }
}
