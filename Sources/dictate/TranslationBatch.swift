import DictateCore
import Foundation

@MainActor
final class TranslationBatch {
    enum Outcome: Equatable {
        case completed
        case timedOut
        case cancelled
    }

    private var pending: Set<SegmentID> = []
    private var waiter: CheckedContinuation<Outcome, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var terminalOutcome: Outcome?

    func add(_ id: SegmentID) {
        guard terminalOutcome == nil else { return }
        pending.insert(id)
    }

    func complete(_ id: SegmentID) {
        pending.remove(id)
        if pending.isEmpty, waiter != nil {
            resolve(.completed)
        }
    }

    func remove(_ id: SegmentID) {
        complete(id)
    }

    func wait(timeoutNanoseconds: UInt64) async -> Outcome {
        if let terminalOutcome { return terminalOutcome }
        if pending.isEmpty { return .completed }

        return await withCheckedContinuation { continuation in
            precondition(waiter == nil, "TranslationBatch supports one waiter")
            waiter = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.resolve(.timedOut)
            }
        }
    }

    func cancel() {
        resolve(.cancelled)
    }

    private func resolve(_ outcome: Outcome) {
        guard terminalOutcome == nil else { return }
        terminalOutcome = outcome
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = waiter
        waiter = nil
        continuation?.resume(returning: outcome)
    }
}
