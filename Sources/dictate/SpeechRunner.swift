@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import DictateCore
import Foundation
import Speech

enum SpeechError: Error, CustomStringConvertible {
    case unavailable(String)
    case io(String)

    var description: String {
        switch self {
        case .unavailable(let message), .io(let message): return message
        }
    }
}

/// Format conversion used from the Core Audio realtime callback.
enum MicBufferConverter {
    static func convert(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outFrames) else { return nil }
        var conversionError: NSError?
        let consumed = ConsumeFlag()
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed.done {
                status.pointee = .noDataNow
                return nil
            }
            consumed.done = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil else { return nil }
        return output
    }
}

private final class ConsumeFlag: @unchecked Sendable {
    var done = false
}

enum MicLevelMeter {
    static func normalizedLevel(for buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
            return 0
        }

        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (decibels + 52) / 42))
    }
}

@available(macOS 26.0, *)
private final class PreparedSpeechSession: @unchecked Sendable {
    let cacheKey: String
    let transcriber: DictationTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat

    init(
        cacheKey: String,
        transcriber: DictationTranscriber,
        analyzer: SpeechAnalyzer,
        format: AVAudioFormat
    ) {
        self.cacheKey = cacheKey
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
    }
}

/// Keeps one fully prepared analyzer per language. Checkout consumes the slot;
/// the runner replenishes it after the utterance has reached a terminal state.
@available(macOS 26.0, *)
private actor SpeechSessionPool {
    static let shared = SpeechSessionPool()

    private var slots: [String: Task<PreparedSpeechSession, Error>] = [:]

    func preheat(localeIdentifier: String) async throws {
        let key = Self.key(for: localeIdentifier)
        let task = slot(for: key)
        do {
            _ = try await task.value
        } catch {
            slots[key] = nil
            throw error
        }
    }

    func checkout(localeIdentifier: String) async throws -> PreparedSpeechSession {
        let key = Self.key(for: localeIdentifier)
        let task = slots.removeValue(forKey: key) ?? Self.makeTask(for: key)
        return try await task.value
    }

    func replenish(localeIdentifier: String) {
        let key = Self.key(for: localeIdentifier)
        guard slots[key] == nil else { return }
        slots[key] = Self.makeTask(for: key)
    }

    private func slot(for key: String) -> Task<PreparedSpeechSession, Error> {
        if let task = slots[key] {
            return task
        }
        let task = Self.makeTask(for: key)
        slots[key] = task
        return task
    }

    private static func makeTask(for key: String) -> Task<PreparedSpeechSession, Error> {
        Task(priority: .userInitiated) {
            try await SpeechRunner.makePreparedSession(localeIdentifier: key)
        }
    }

    private static func key(for localeIdentifier: String) -> String {
        Locale(identifier: localeIdentifier).identifier
    }
}

/// One SpeechRunner belongs to exactly one utterance. Actor isolation prevents
/// start/finish/cancel from mutating the audio and analyzer state concurrently.
@available(macOS 26.0, *)
actor SpeechRunner {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var consumeTask: Task<Void, Error>?
    private var tapInstalled = false
    private var hasStarted = false
    private var isTerminal = false
    private var finishRequested = false
    private var inputSequenceStarted = false
    private var checkedOutLocaleIdentifier: String?

    static func preheatModel(localeIdentifier: String?) async throws {
        guard let localeIdentifier else { return }
        try await SpeechSessionPool.shared.preheat(localeIdentifier: localeIdentifier)
    }

    static func preheatModels(localeIdentifiers: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for localeIdentifier in Set(localeIdentifiers) {
                group.addTask {
                    try? await preheatModel(localeIdentifier: localeIdentifier)
                }
            }
        }
    }

    func start(
        localeIdentifier: String?,
        onAudioLevel: @escaping @Sendable (Float) -> Void,
        onHypothesis: @escaping @Sendable (ASRHypothesis) -> Void
    ) async throws {
        guard !hasStarted else {
            throw SpeechError.io("同一个听写会话不能重复启动")
        }
        hasStarted = true
        try checkMayStartAudio()

        do {
            let requestedLocale = localeIdentifier ?? "zh-CN"
            let prepared = try await SpeechSessionPool.shared.checkout(
                localeIdentifier: requestedLocale
            )
            checkedOutLocaleIdentifier = prepared.cacheKey
            let transcriber = prepared.transcriber
            let analyzer = prepared.analyzer
            let format = prepared.format
            self.analyzer = analyzer
            try checkMayStartAudio()

            consumeTask = Task {
                for try await result in transcriber.results {
                    let hypothesis = ASRHypothesis(
                        text: String(result.text.characters),
                        isFinal: result.isFinal,
                        t0: result.range.start.seconds.isFinite ? result.range.start.seconds : 0,
                        t1: result.range.end.seconds.isFinite ? result.range.end.seconds : 0
                    )
                    await MainActor.run {
                        onHypothesis(hypothesis)
                    }
                }
            }

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
                bufferingPolicy: .bufferingNewest(128)
            )
            self.continuation = continuation
            try await analyzer.start(inputSequence: stream)
            inputSequenceStarted = true
            try checkMayStartAudio()

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
                throw SpeechError.unavailable("无法转换麦克风格式 \(inputFormat) → \(format)")
            }

            self.engine = engine
            input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
                let audioLevel = MicLevelMeter.normalizedLevel(for: buffer)
                DispatchQueue.main.async {
                    onAudioLevel(audioLevel)
                }
                guard let output = MicBufferConverter.convert(
                    buffer: buffer,
                    converter: converter,
                    format: format
                ) else {
                    return
                }
                continuation.yield(AnalyzerInput(buffer: output))
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            try checkMayStartAudio()
        } catch {
            if finishRequested {
                stopAudioInput()
                if !inputSequenceStarted {
                    await cancelInternal()
                }
                return
            }
            await cancelInternal()
            throw error
        }
    }

    /// Registers release before the task that is still preparing the model is
    /// cancelled. Reentrant start checkpoints then cannot proceed to the mic.
    func requestFinish() {
        guard !isTerminal else { return }
        finishRequested = true
        stopAudioInput()
    }

    /// Stops audio, consumes all queued input, finalizes module output, then
    /// waits until the result stream is fully drained before returning.
    func finish() async throws {
        guard !isTerminal else { return }
        isTerminal = true
        stopAudioInput()

        guard let analyzer else {
            clearState()
            return
        }

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await consumeTask?.value
            clearState()
        } catch {
            await analyzer.cancelAndFinishNow()
            _ = try? await consumeTask?.value
            clearState()
            throw error
        }
    }

    func cancel() async {
        guard !isTerminal else { return }
        isTerminal = true
        await cancelInternal()
    }

    private func cancelInternal() async {
        stopAudioInput()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        _ = try? await consumeTask?.value
        clearState()
    }

    private func stopAudioInput() {
        engine?.stop()
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        continuation?.finish()
        continuation = nil
        engine = nil
    }

    private func clearState() {
        let localeIdentifier = checkedOutLocaleIdentifier
        checkedOutLocaleIdentifier = nil
        continuation = nil
        consumeTask = nil
        analyzer = nil
        engine = nil
        tapInstalled = false
        if let localeIdentifier {
            Task {
                await SpeechSessionPool.shared.replenish(
                    localeIdentifier: localeIdentifier
                )
            }
        }
    }

    private func checkMayStartAudio() throws {
        try Task.checkCancellation()
        if finishRequested || isTerminal {
            throw CancellationError()
        }
    }

    static func transcribeFile(
        _ url: URL,
        localeIdentifier: String?,
        onHypothesis: @escaping @Sendable (ASRHypothesis) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechError.unavailable("SpeechTranscriber 不可用，需要 macOS 26+")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpeechError.io("找不到音频: \(url.path)")
        }

        let locale = try await pickSpeechLocale(preferred: localeIdentifier)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        try await ensureAssets(for: transcriber, locale: locale)

        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let consume: Void = {
            for try await result in transcriber.results {
                let hypothesis = ASRHypothesis(
                    text: String(result.text.characters),
                    isFinal: result.isFinal,
                    t0: result.range.start.seconds.isFinite ? result.range.start.seconds : 0,
                    t1: result.range.end.seconds.isFinite ? result.range.end.seconds : 0
                )
                await MainActor.run {
                    onHypothesis(hypothesis)
                }
            }
        }()

        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        try await consume
    }

    private static func makeDictationTranscriber(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [.audioTimeRange]
        )
    }

    fileprivate static func makePreparedSession(
        localeIdentifier: String
    ) async throws -> PreparedSpeechSession {
        let locale = try await pickDictationLocale(preferred: localeIdentifier)
        let transcriber = makeDictationTranscriber(locale: locale)
        try await ensureAssets(for: transcriber, locale: locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .high, modelRetention: .processLifetime)
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw SpeechError.unavailable("没有可用的麦克风音频格式")
        }
        try await analyzer.prepareToAnalyze(in: format)
        return PreparedSpeechSession(
            cacheKey: localeIdentifier,
            transcriber: transcriber,
            analyzer: analyzer,
            format: format
        )
    }

    private static func pickDictationLocale(preferred: String?) async throws -> Locale {
        if let preferred,
           let match = await DictationTranscriber.supportedLocale(
               equivalentTo: Locale(identifier: preferred)
           )
        {
            return match
        }
        for identifier in ["zh-CN", "zh-Hans", "en-US", Locale.current.identifier] {
            if let match = await DictationTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)
            ) {
                return match
            }
        }
        if let first = await DictationTranscriber.installedLocales.first {
            return first
        }
        throw SpeechError.unavailable("本机没有可用的听写语言包")
    }

    private static func pickSpeechLocale(preferred: String?) async throws -> Locale {
        if let preferred {
            if let match = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: preferred)
            ) {
                return match
            }
            throw SpeechError.unavailable("没有与 \(preferred) 匹配的 SpeechTranscriber 语言")
        }
        for identifier in ["zh-CN", "zh-Hans", "en-US", Locale.current.identifier] {
            if let match = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)
            ) {
                return match
            }
        }
        if let first = await SpeechTranscriber.installedLocales.first {
            return first
        }
        throw SpeechError.unavailable("本机没有可用的 SpeechTranscriber 语言包")
    }

    private static func ensureAssets(for module: any SpeechModule, locale: Locale) async throws {
        _ = try? await AssetInventory.reserve(locale: locale)
        let status = await AssetInventory.status(forModules: [module])
        switch status {
        case .installed:
            return
        case .unsupported:
            throw SpeechError.unavailable("不支持 \(locale.identifier) 的语音识别资源")
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            } else {
                throw SpeechError.unavailable("未安装 \(locale.identifier) 的语音识别资源")
            }
        @unknown default:
            throw SpeechError.unavailable("语音识别资源状态未知（\(locale.identifier)）")
        }
    }
}
