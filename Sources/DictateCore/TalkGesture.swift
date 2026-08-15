public struct TalkGesture: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case pending
        case talking
        case suppressed
    }

    public enum Action: Sendable, Equatable {
        case scheduleActivation
        case cancelScheduledActivation
        case startTalk
        case stopTalk
        case cancelTalk
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public mutating func optionChanged(isDown: Bool) -> [Action] {
        if isDown {
            guard phase == .idle else { return [] }
            phase = .pending
            return [.scheduleActivation]
        }

        switch phase {
        case .pending:
            phase = .idle
            return [.cancelScheduledActivation]
        case .talking:
            phase = .idle
            return [.stopTalk]
        case .suppressed:
            phase = .idle
            return [.cancelScheduledActivation]
        case .idle:
            return []
        }
    }

    public mutating func activationTimerFired() -> [Action] {
        guard phase == .pending else { return [] }
        phase = .talking
        return [.startTalk]
    }

    public mutating func otherKeyPressed() -> [Action] {
        switch phase {
        case .pending:
            phase = .suppressed
            return [.cancelScheduledActivation]
        case .talking:
            phase = .suppressed
            return [.cancelTalk]
        case .idle, .suppressed:
            return []
        }
    }

    public mutating func reset(cancelActive: Bool) -> [Action] {
        let previous = phase
        phase = .idle
        switch previous {
        case .pending, .suppressed:
            return [.cancelScheduledActivation]
        case .talking where cancelActive:
            return [.cancelTalk]
        case .idle, .talking:
            return []
        }
    }
}
