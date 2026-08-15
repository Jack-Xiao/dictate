import Foundation

public struct ASRHypothesis: Sendable, Equatable, Codable {
    public var text: String
    public var isFinal: Bool
    public var t0: Double
    public var t1: Double

    public init(text: String, isFinal: Bool, t0: Double, t1: Double) {
        self.text = text
        self.isFinal = isFinal
        self.t0 = t0
        self.t1 = t1
    }
}

public struct SegmentID: Sendable, Hashable, Equatable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct CommittedLine: Sendable, Equatable {
    public let id: SegmentID
    public var text: String
    public var translation: String?
    public var t0: Double
    public var t1: Double

    public init(
        id: SegmentID = SegmentID(),
        text: String,
        translation: String? = nil,
        t0: Double = 0,
        t1: Double = 0
    ) {
        self.id = id
        self.text = text
        self.translation = translation
        self.t0 = t0
        self.t1 = t1
    }
}

public struct DictateSession: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case listening
        case stopping
    }

    public private(set) var committed: [CommittedLine] = []
    public private(set) var partial: String = ""
    public private(set) var phase: Phase = .idle
    private var draftT0: Double = 0
    private var draftT1: Double = 0

    public init() {}

    public var displayCommitted: String {
        TextJoiner.join(committed.map(\.text))
    }

    public var displayText: String {
        TextJoiner.join(committed.map(\.text) + (partial.isEmpty ? [] : [partial]))
    }

    public var displayTranslation: String {
        committed.compactMap(\.translation).joined(separator: "\n")
    }

    public var sourceText: String {
        TextJoiner.join(committed.map(\.text))
    }

    public var insertText: String {
        if committed.contains(where: { $0.translation != nil }) {
            return Self.payload(from: committed)
        }
        return sourceText
    }

    public mutating func begin() {
        committed = []
        partial = ""
        draftT0 = 0
        draftT1 = 0
        phase = .listening
    }

    /// Show volatile text immediately. Volatile text never mutates committed
    /// segments. A later FINAL may replace overlapping earlier FINALs.
    @discardableResult
    public mutating func ingest(_ hypothesis: ASRHypothesis) -> SegmentID? {
        guard phase == .listening || phase == .stopping else { return nil }
        let text = hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if hypothesis.isFinal {
            if Self.overlaps(draftT0, draftT1, hypothesis.t0, hypothesis.t1) {
                partial = ""
                draftT0 = 0
                draftT1 = 0
            }
            committed.removeAll { Self.overlaps($0.t0, $0.t1, hypothesis.t0, hypothesis.t1) }
            let line = CommittedLine(text: text, t0: hypothesis.t0, t1: hypothesis.t1)
            committed.append(line)
            committed.sort { $0.t0 < $1.t0 }
            return line.id
        }

        partial = text
        draftT0 = hypothesis.t0
        draftT1 = hypothesis.t1
        return nil
    }

    public mutating func setTranslation(_ translation: String, for id: SegmentID) {
        guard let index = committed.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        committed[index].translation = trimmed
    }

    public mutating func markStopping() {
        if phase == .listening {
            phase = .stopping
        }
    }

    @discardableResult
    public mutating func finish(includeDanglingPartial: Bool = false) -> String {
        if includeDanglingPartial, !partial.isEmpty {
            committed.append(CommittedLine(text: partial, t0: draftT0, t1: draftT1))
            committed.sort { $0.t0 < $1.t0 }
        }
        partial = ""
        draftT0 = 0
        draftT1 = 0
        phase = .idle
        return insertText
    }

    public mutating func cancel() {
        committed = []
        partial = ""
        draftT0 = 0
        draftT1 = 0
        phase = .idle
    }

    public static func payload(from lines: [CommittedLine]) -> String {
        lines.compactMap { line -> String? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let translation = line.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
               !translation.isEmpty
            {
                return "\(text)\n\(translation)"
            }
            return text
        }
        .joined(separator: "\n\n")
    }

    static func overlaps(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Bool {
        a0 < b1 && b0 < a1
    }
}
