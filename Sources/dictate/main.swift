import AppKit
import DictateCore
import Foundation

let options = parseArgs(Array(CommandLine.arguments.dropFirst()))

if #available(macOS 26.0, *) {
    if let wav = options.wavPath {
        Task { @MainActor in
            do {
                try await runWav(
                    wav,
                    locale: options.locale ?? "zh-CN",
                    translate: options.translationEnabled ?? false
                )
                exit(0)
            } catch {
                fputs("error: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(
        localeIdentifier: options.locale,
        translationEnabled: options.translationEnabled,
        commitMode: options.commitMode,
        previewHUD: options.previewHUD
    )
    Retain.box = delegate
    app.delegate = delegate
    app.run()
} else {
    fputs("error: Dictate 需要 macOS 26+\n", stderr)
    exit(1)
}

struct CLIOptions {
    var locale: String?
    var wavPath: String?
    var translationEnabled: Bool?
    var commitMode: DictateCommitMode?
    var previewHUD = false
}

func parseArgs(_ args: [String]) -> CLIOptions {
    if args.contains("-h") || args.contains("--help") {
        print("""
        dictate — 本机流式听写（刘海 HUD + 松手插入）

          dictate [--locale zh-CN|en-US] [--translate|--no-translate] [--insert|--copy] [--preview-hud]
          dictate --wav file.wav [--locale zh-CN] [--translate]

        识别语言、翻译和完成方式可在菜单栏切换；设置会自动保存。
        --insert 把结果送回原输入框；--copy 只复制到剪贴板。
        翻译开启时提交「FINAL 原文 + 译文」，超时或不可用时回退原文。
        """)
        exit(0)
    }
    var options = CLIOptions()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--translate":
            options.translationEnabled = true
            i += 1
        case "--no-translate":
            options.translationEnabled = false
            i += 1
        case "--insert":
            options.commitMode = .insert
            i += 1
        case "--copy":
            options.commitMode = .copy
            i += 1
        case "--preview-hud":
            options.previewHUD = true
            i += 1
        case "--locale":
            let next = i + 1
            guard next < args.count else {
                fputs("error: --locale needs an identifier (e.g. zh-CN)\n", stderr)
                exit(2)
            }
            options.locale = args[next]
            i += 2
        case "--wav":
            let next = i + 1
            guard next < args.count else {
                fputs("error: --wav needs a file path\n", stderr)
                exit(2)
            }
            options.wavPath = args[next]
            i += 2
        default:
            fputs("error: unknown argument \(args[i])\n", stderr)
            exit(2)
        }
    }
    return options
}

@MainActor
@available(macOS 26.0, *)
func runWav(_ path: String, locale: String, translate: Bool) async throws {
    var session = DictateSession()
    session.begin()
    try await SpeechRunner.transcribeFile(
        URL(fileURLWithPath: path),
        localeIdentifier: locale
    ) { hyp in
        MainActor.assumeIsolated {
            session.ingest(hyp)
            let kind = hyp.isFinal ? "FINAL" : "PARTIAL"
            print("\(kind) \(hyp.text)")
            fflush(stdout)
        }
    }
    if translate {
        let translator = AppleTranslator()
        for line in session.committed {
            let translated = try await translator.translate(line.text, sourceLang: nil)
            session.setTranslation(translated, for: line.id)
            print("TRANS \(translated)")
            fflush(stdout)
        }
    }
    let payload = session.finish(includeDanglingPartial: false)
    print("---")
    print(payload)
    print("---")
}

enum Retain {
    @available(macOS 26.0, *)
    nonisolated(unsafe) static var box: AppDelegate?
}

@available(macOS 26.0, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private let localeIdentifier: String?
    private let translationEnabled: Bool?
    private let commitMode: DictateCommitMode?
    private let previewHUD: Bool

    init(
        localeIdentifier: String?,
        translationEnabled: Bool?,
        commitMode: DictateCommitMode?,
        previewHUD: Bool
    ) {
        self.localeIdentifier = localeIdentifier
        self.translationEnabled = translationEnabled
        self.commitMode = commitMode
        self.previewHUD = previewHUD
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        controller.start(
            localeIdentifier: localeIdentifier,
            translationEnabled: translationEnabled,
            commitMode: commitMode,
            previewHUD: previewHUD
        )
        self.controller = controller
    }
}
