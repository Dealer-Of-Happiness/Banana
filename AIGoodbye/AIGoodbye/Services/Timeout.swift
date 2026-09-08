//
//  Timeout.swift
//  AIGoodbye
//
//  Waiting for something that might never finish.
//
//  Deliberately not a task group. `withTaskGroup` waits for every child
//  before it returns, and `cancelAll()` only raises a flag - so racing a
//  framework call against a sleep inside a group hangs the group whenever
//  that call ignores cancellation. Which is the one case a timeout exists
//  for.
//
//  Here the slow work runs unstructured and is simply abandoned when the
//  clock wins. It keeps running in the background until it finishes or is
//  collected, but it no longer holds the caller - and in this app the caller
//  is a Stop button with a live microphone behind it.
//

import Foundation

enum Timeout {

    /// Run `work`, giving up after `seconds`.
    static func run(seconds: Double, _ work: @escaping @Sendable () async -> Void) async {
        let gate = OneShotGate()
        let job = Task.detached(priority: .userInitiated) {
            await work()
            gate.fire()
        }
        let timer = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            gate.fire()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.arm(continuation)
        }
        job.cancel()
        timer.cancel()
    }

    /// Wait for `task`, but never longer than `seconds`.
    static func join(_ task: Task<Void, Never>?, seconds: Double) async {
        guard let task else { return }
        await run(seconds: seconds) { await task.value }
    }

    /// Wait for an unstructured task, but let the caller's own cancellation
    /// through immediately.
    ///
    /// `await task.value` on a task that is not a child is not a
    /// cancellation point: a cancelled caller sits there until the task
    /// finishes, however long that is. That is how Stop did nothing while a
    /// shared 1.8 GB model load was in flight - the chat's wait was
    /// cancelled and simply kept waiting. This returns `CancellationError`
    /// the moment the caller is cancelled, and leaves the task itself
    /// running for whoever else is waiting on it.
    static func awaitCancellable(_ task: Task<Void, Error>) async throws {
        let gate = ResultGate()
        let watcher = Task.detached {
            do {
                try await task.value
                gate.fire(.success(()))
            } catch {
                gate.fire(.failure(error))
            }
        }
        defer { watcher.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.arm(continuation)
            }
        } onCancel: {
            gate.fire(.failure(CancellationError()))
        }
    }
}

/// `OneShotGate` for a throwing wait: the first result wins, later ones are
/// dropped.
private nonisolated final class ResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func arm(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func fire(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

/// Resumes a continuation exactly once, whichever racer arrives first.
private nonisolated final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasFired = false

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if hasFired {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func fire() {
        lock.lock()
        guard !hasFired else { lock.unlock(); return }
        hasFired = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}
