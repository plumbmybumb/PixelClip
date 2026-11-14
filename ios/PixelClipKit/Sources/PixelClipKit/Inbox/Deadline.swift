import Foundation

/// `withDeadline` gave up waiting.
public struct DeadlineExceeded: Error, Sendable, Equatable {
    public init() {}
}

/// Runs `work` off the caller's actor and returns its result, or throws `DeadlineExceeded` after
/// `seconds`. The work is cancelled then, but not waited for: a parser that never looks at
/// cancellation can't hold the caller up (it finishes, or not, on its own thread).
public func withDeadline<T: Sendable>(seconds: Double, priority: TaskPriority? = nil,
                                      _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = DeadlineGate<T>()
    let worker = Task.detached(priority: priority) {
        do { gate.settle(.success(try await work())) } catch { gate.settle(.failure(error)) }
    }
    let timer = Task.detached {
        guard await sleepWhileRunning(seconds: seconds) else { return }
        if gate.settle(.failure(DeadlineExceeded())) { worker.cancel() }
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in gate.wait(continuation) }
    } onCancel: {
        worker.cancel()
    }
}

/// Sleeps for `seconds` of time in which this process could run, in quarter-second slices. An app that
/// is suspended in the middle (the person switched away) doesn't come back to find the whole wait
/// already over: at most one slice passes while it is away, so a deadline measures the work, not the
/// pause. Returns false when the task was cancelled first.
public func sleepWhileRunning(seconds: Double) async -> Bool {
    let slice = 0.25
    var left = seconds
    while left > 0 {
        do { try await Task.sleep(for: .seconds(min(slice, left))) } catch { return false }
        left -= slice
    }
    return !Task.isCancelled
}

/// The first result wins; the continuation is resumed exactly once, whichever arrives first.
private final class DeadlineGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<T, any Error>?

    /// True when this result is the one that counts.
    @discardableResult
    func settle(_ r: Result<T, any Error>) -> Bool {
        let (won, waiting): (Bool, CheckedContinuation<T, any Error>?) = lock.withLock {
            guard result == nil else { return (false, nil) }
            result = r
            let c = continuation
            continuation = nil
            return (true, c)
        }
        waiting?.resume(with: r)
        return won
    }

    func wait(_ c: CheckedContinuation<T, any Error>) {
        let ready: Result<T, any Error>? = lock.withLock {
            if let result { return result }
            continuation = c
            return nil
        }
        if let ready { c.resume(with: ready) }
    }
}
